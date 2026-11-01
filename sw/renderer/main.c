/*
 * HUB75 rotating-display PS renderer (bare-metal, Vitis 2026.1).
 *
 * The PS renders 64 complete 128x64 slices into a non-active DDR frame buffer,
 * flushes the data cache, writes frame_base through AXI GPIO, then toggles the
 * submit bit. The PL latches the new base only at an IR revolution boundary.
 *
 * Test pattern:
 *   slice 0        : both halves white (angular anchor)
 *   other slices   : 4-pixel red bar on the rgb1/upper half,
 *                    4-pixel blue bar on the rgb2/lower half,
 *                    column = 2*slice
 * The upper/lower colours are deliberately different so the panel wiring can
 * be identified; if the halves are swapped, swap the rgb_upper/rgb_lower
 * arguments in render_pattern().
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

static void render_pattern(uint8_t *frame, uint32_t frame_no)
{
    int slice, row_addr, col;

    (void)frame_no;
    hub75_frame_clear(frame);

    for (slice = 0; slice < HUB75_SLICES; slice++) {
        int bar_start = 2 * slice;
        for (row_addr = 0; row_addr < HUB75_ROW_ADDRS; row_addr++) {
            for (col = 0; col < HUB75_COLS; col++) {
                uint8_t upper;
                uint8_t lower;

                if (slice == 0) {
                    upper = 7;
                    lower = 7;
                } else if (col >= bar_start && col < bar_start + 4) {
                    upper = 4;   /* red */
                    lower = 1;   /* blue */
                } else {
                    upper = 0;
                    lower = 0;
                }
                hub75_frame_set_pixel(frame, slice, row_addr, col,
                                      upper, lower);
            }
        }
    }
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

        render_pattern(frame, frame_no);
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
        sleep(1);
    }

    return 0;
}
