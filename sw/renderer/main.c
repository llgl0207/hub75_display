/*
 * HUB75 rotating-display PS renderer (bare-metal, Vitis 2026.1).
 *
 * The PS renders 64 complete 128x64 slices into a non-active DDR frame buffer,
 * flushes the data cache, writes frame_base through AXI GPIO, then toggles the
 * submit bit. The PL latches the new base only at an IR revolution boundary
 * (with no IR, the reader's bench fallback uses the 1800 RPM slice wrap).
 *
 * Stationary animation:
 *   All 64 slices show the same 128x64 image, so a non-rotating panel shows a
 *   stable 2D picture (no IR and no motor needed). A white border and crosshair
 *   stay fixed; a coloured ball bounces across the full 64-row panel and its
 *   colour cycles every four frames. The image is rendered once and memcpy'd
 *   into the other 63 slices.
 *
 * For the rotating/volumetric version, render a different image per slice
 * (for example the original angular anchor + red/blue bars) instead of copying.
 * If the upper/lower halves appear swapped, swap the rgb_upper/rgb_lower
 * arguments at the call site.
 *
 * Build: create a Vitis application from board/output/hub75_ps_stage1.xsa,
 * add the sw/common C/H files and this file to the app src, build, and run
 * with Program FPGA + Reset entire system. See sw/README.md.
 */

#include "xgpio.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xparameters.h"
#include "sleep.h"
#include <stdarg.h>
#include <stdint.h>
#include <string.h>

#include "hub75_frame.h"
#include "hub75_regs.h"

static XGpio gpio_ctrl;
static XGpio gpio_status;

/*
 * Console: this Mizar-Z7 has the CP2102 USB-UART wired to PS UART1 on
 * MIO48/MIO49, not to UART0 on MIO14/MIO15 as the vendor table suggests.
 * ps7_init leaves MIO48/49 as GPIO and the UART1 clocks off, so the pin mux,
 * the two clock gates and the UART1 registers are programmed here.
 * 115200 8N1 with the 100 MHz UART reference clock: 100e6/(124*(6+1)).
 */
#define CONSOLE_UART_BASE   0xE0001000u
#define SLCR_UNLOCK         0xF8000008u
#define SLCR_LOCK           0xF8000004u
#define SLCR_MIO48          0xF80007C0u
#define SLCR_MIO49          0xF80007C4u
#define SLCR_UART_CLK_CTRL  0xF8000154u
#define SLCR_APER_CLK_CTRL  0xF800012Cu
#define UART_CR             0x00u
#define UART_MR             0x04u
#define UART_BAUDGEN        0x18u
#define UART_SR             0x2Cu
#define UART_TX_FIFO        0x30u
#define UART_BAUDDIV        0x34u

static void console_init(void)
{
    Xil_Out32(SLCR_UNLOCK, 0x0000DF0Du);
    Xil_Out32(SLCR_MIO48, 0x000012E0u);  /* UART1 TxD, output, LVCMOS18 */
    Xil_Out32(SLCR_MIO49, 0x000012E1u);  /* UART1 RxD, input, LVCMOS18 */
    Xil_Out32(SLCR_UART_CLK_CTRL,
              Xil_In32(SLCR_UART_CLK_CTRL) | 0x2u);      /* CLKACT1 */
    Xil_Out32(SLCR_APER_CLK_CTRL,
              Xil_In32(SLCR_APER_CLK_CTRL) | (1u << 21)); /* UART1 APB */
    Xil_Out32(SLCR_LOCK, 0x0000767Bu);

    Xil_Out32(CONSOLE_UART_BASE + UART_CR, 0x03u);   /* reset TX/RX */
    Xil_Out32(CONSOLE_UART_BASE + UART_MR, 0x20u);   /* 8N1, no parity */
    Xil_Out32(CONSOLE_UART_BASE + UART_BAUDGEN, 124u);
    Xil_Out32(CONSOLE_UART_BASE + UART_BAUDDIV, 6u);
    Xil_Out32(CONSOLE_UART_BASE + UART_CR, 0x114u);  /* TX_EN, RX_EN */
}

static void console_putc(char c)
{
    while (Xil_In32(CONSOLE_UART_BASE + UART_SR) & 0x10u) {
        /* TX FIFO full */
    }
    Xil_Out32(CONSOLE_UART_BASE + UART_TX_FIFO, (uint32_t)(uint8_t)c);
}

static void console_puts(const char *s)
{
    while (*s != '\0') console_putc(*s++);
}

static void console_put_unsigned(uint32_t value, uint32_t base)
{
    char buf[11];
    int i = 0;

    if (value == 0u) {
        console_putc('0');
        return;
    }
    while (value != 0u) {
        uint32_t digit = value % base;
        buf[i++] = (char)(digit < 10u ? '0' + digit : 'a' + digit - 10u);
        value /= base;
    }
    while (i > 0) console_putc(buf[--i]);
}

static void console_printf(const char *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    while (*fmt != '\0') {
        if (*fmt != '%') {
            console_putc(*fmt++);
            continue;
        }
        fmt++;
        switch (*fmt) {
        case '%':
            console_putc('%');
            break;
        case 's':
            console_puts(va_arg(ap, const char *));
            break;
        case 'c':
            console_putc((char)va_arg(ap, int));
            break;
        case 'u':
            console_put_unsigned(va_arg(ap, uint32_t), 10u);
            break;
        case 'd':
            console_put_unsigned((uint32_t)va_arg(ap, int), 10u);
            break;
        case 'x':
            console_put_unsigned(va_arg(ap, uint32_t), 16u);
            break;
        default:
            console_putc('%');
            console_putc(*fmt);
            break;
        }
        if (*fmt != '\0') fmt++;
    }
    va_end(ap);
}

static int gpio_init(void)
{
    if (XGpio_Initialize(&gpio_ctrl, HUB75_GPIO_CTRL_INIT_ARG) != XST_SUCCESS)
        return XST_FAILURE;
    if (XGpio_Initialize(&gpio_status, HUB75_GPIO_STATUS_INIT_ARG) != XST_SUCCESS)
        return XST_FAILURE;

    XGpio_SetDataDirection(&gpio_ctrl, HUB75_GPIO_CH1, 0x00000000u);
    XGpio_SetDataDirection(&gpio_ctrl, HUB75_GPIO_CH2, 0x00000000u);
    XGpio_SetDataDirection(&gpio_status, HUB75_GPIO_CH1, 0xFFFFFFFFu);
    XGpio_SetDataDirection(&gpio_status, HUB75_GPIO_CH2, 0xFFFFFFFFu);
    return XST_SUCCESS;
}

static uint32_t status_read(void)
{
    return XGpio_DiscreteRead(&gpio_status, HUB75_GPIO_CH1);
}

/* IR revolution period measured by the PL (mean of the last five intervals).
 * Zero until five complete IR intervals have been captured. */
static uint32_t period_read(void)
{
    return XGpio_DiscreteRead(&gpio_status, HUB75_GPIO_CH2);
}

static int ddr_test(volatile uint32_t *base, uint32_t bytes)
{
    uint32_t words = bytes / 4u;
    uint32_t i;

    for (i = 0; i < words; i++) base[i] = 0xA5A5A5A5u;
    for (i = 0; i < words; i++)
        if (base[i] != 0xA5A5A5A5u) return 0;

    for (i = 0; i < words; i++) base[i] = ~i;
    for (i = 0; i < words; i++)
        if (base[i] != ~i) return 0;

    return 1;
}

/* Static background: white frame around each 32-row half plus a dim cyan
 * crosshair. Both halves get the same pattern so the 2D image is symmetric. */
static void background_pixel(int row_addr, int col,
                             uint8_t *upper, uint8_t *lower)
{
    *upper = 0;
    *lower = 0;
    if (row_addr < 2 || row_addr >= HUB75_ROW_ADDRS - 2 ||
        col < 2 || col >= HUB75_COLS - 2) {
        *upper = 7;
        *lower = 7;
    } else if (row_addr == HUB75_ROW_ADDRS / 2 ||
               col == HUB75_COLS / 2) {
        *upper = 3;
        *lower = 3;
    }
}

static uint8_t background_slice[HUB75_SLICE_BYTES];

static void build_background(void)
{
    int row, col;

    memset(background_slice, 0, sizeof(background_slice));
    for (row = 0; row < HUB75_ROW_ADDRS; row++)
        for (col = 0; col < HUB75_COLS; col++) {
            uint8_t upper, lower;
            background_pixel(row, col, &upper, &lower);
            hub75_frame_set_pixel(background_slice, 0, row, col,
                                  upper, lower);
        }
}

/*
 * Stationary 2D animation. All 64 slices get the same image, so a non-rotating
 * panel shows one stable picture. The ball moves over the full 64-row panel:
 * row 0..31 is the rgb1/upper half, row 32..63 is the rgb2/lower half.
 * Only the ball's 15x15 bounding box is updated; the background is copied in.
 */
static void render_frame(uint8_t *frame, uint32_t frame_no)
{
    static const uint8_t ball_colours[3] = { 4, 2, 1 }; /* red, green, blue */
    const int ball_r2 = 7 * 7;
    int t = (int)((frame_no * 2u) % 198u);
    int bx = 10 + (t < 99 ? t : 197 - t);          /* 10..108, bounces */
    int u = (int)(frame_no % 126u);
    int by = (u < 64) ? u : 125 - u;               /* 0..63, full panel */
    uint8_t colour = ball_colours[(frame_no >> 2) % 3u];
    int pr, pc, slice;

    memcpy(frame, background_slice, HUB75_SLICE_BYTES);

    for (pr = by - 7; pr <= by + 7; pr++) {
        int row_addr;
        int dy;
        if (pr < 0 || pr >= HUB75_ROWS) continue;
        row_addr = pr % HUB75_ROW_ADDRS;
        dy = pr - by;
        for (pc = bx - 7; pc <= bx + 7; pc++) {
            uint8_t upper, lower;
            int dx;
            if (pc < 0 || pc >= HUB75_COLS) continue;
            dx = pc - bx;
            if (dx * dx + dy * dy > ball_r2) continue;
            background_pixel(row_addr, pc, &upper, &lower);
            if (pr < HUB75_ROW_ADDRS) upper = colour;
            else lower = colour;
            hub75_frame_set_pixel(frame, 0, row_addr, pc, upper, lower);
        }
    }

    for (slice = 1; slice < HUB75_SLICES; slice++)
        memcpy(frame + slice * HUB75_SLICE_BYTES,
               frame, HUB75_SLICE_BYTES);
}

int main(void)
{
    uint8_t *frames[2] = { (uint8_t *)HUB75_FRAME_A,
                           (uint8_t *)HUB75_FRAME_B };
    uint32_t frame_no = 0;
    uint32_t toggle = 0;
    uint32_t last_done = 0;

    console_init();
    console_printf("\r\nHUB75 PS renderer\r\n");

    if (gpio_init() != XST_SUCCESS) {
        console_printf("GPIO init FAIL\r\n");
        return -1;
    }

    Xil_DCacheDisable();
    console_printf("DDR test ...\r\n");
    if (!ddr_test((volatile uint32_t *)HUB75_FRAME_A, 0x00200000u) ||
        !ddr_test((volatile uint32_t *)HUB75_FRAME_B, 0x00200000u)) {
        console_printf("DDR FAIL\r\n");
        return -1;
    }
    console_printf("DDR PASS\r\n");
    Xil_DCacheEnable();

    hub75_frame_clear(frames[0]);
    hub75_frame_clear(frames[1]);
    Xil_DCacheFlushRange((UINTPTR)frames[0], HUB75_FRAME_BYTES);
    Xil_DCacheFlushRange((UINTPTR)frames[1], HUB75_FRAME_BYTES);
    build_background();

    for (;;) {
        uint8_t *frame = frames[frame_no & 1u];
        uint32_t status = status_read();

        /* Wait for the PL to finish the previous frame before reusing its
         * buffer. The toggle changes when the PL latches a new base at the
         * revolution boundary. */
        if (frame_no > 0) {
            while (((status & HUB75_ST_FRAME_DONE) ? 1u : 0u) == last_done)
                status = status_read();
        }
        last_done = (status & HUB75_ST_FRAME_DONE) ? 1u : 0u;

        render_frame(frame, frame_no);
        Xil_DCacheFlushRange((UINTPTR)frame, HUB75_FRAME_BYTES);

        XGpio_DiscreteWrite(&gpio_ctrl, HUB75_GPIO_CH1, (uint32_t)(UINTPTR)frame);
        (void)XGpio_DiscreteRead(&gpio_ctrl, HUB75_GPIO_CH1);

        toggle ^= 1u;
        XGpio_DiscreteWrite(&gpio_ctrl, HUB75_GPIO_CH2,
                            HUB75_CTRL_ENABLE |
                            HUB75_CTRL_SLICES(HUB75_SLICES) | toggle);

        status = status_read();
        console_printf("frame %u base %x status %x slice %u id %u period %u\r\n",
                   frame_no, (unsigned)(UINTPTR)frame, status,
                   HUB75_ST_SLICE(status), HUB75_ST_FRAME_ID(status),
                   period_read());

        frame_no++;
        usleep(50000);
    }

    return 0;
}
