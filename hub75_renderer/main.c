/*
 * HUB75 rotating-display PS renderer (bare-metal, Vitis 2026.1).
 *
 * HUB75_VOLUMETRIC_TEST = 1 (default): two-ball rotating volume.
 *   The PS renders 64 angular slices of a static 3D scene into a DDR frame
 *   buffer. Slice s is drawn on the panel while the panel is at approximately
 *   s * 360/64 degrees after the IR anchor. The PL latches the frame at an IR
 *   revolution boundary and scans slice s in slot s; the eye integrates the
 *   planar cuts into a solid volume.
 *
 *   Scene, in panel coordinates (x = 0..128 left-to-right, y = 0..64 top-to-
 *   bottom, rotation axis at x = 64 and y = 32):
 *     left ball   centre (-24, 32, 0), radius 12, red
 *     right ball  centre (+24, 32, 0), radius 12, green
 *
 *   The topmost panel row can show a one-row ghost of the previous slot's
 *   last row (row 31). The colour diagnostic confirmed the upper/lower data
 *   and row mapping are correct; the ghost is a scan/panel first-row artifact,
 *   not a frame error. Leaving it for now; the PL can blank row 0 later by
 *   holding OE off for row_addr 0.
 *
 *   For slice angle theta and a point on the panel at horizontal radius r
 *   (r = x - 64) and height y, the point is inside a sphere centred at
 *   (x0, y0, 0) when
 *       (r - x0*cos(theta))^2 + (y - y0)^2 + (x0*sin(theta))^2 <= radius^2.
 *   The 64-entry Q15 sine table avoids linking libm into the bare-metal app.
 *
 *   Row addresses: normal 1/32 mapping. For the upper/rgb1 half row_addr is the
 *   physical y within the half (0 = panel top); for the lower/rgb2 half
 *   row_addr is physical y - 32 (0 = just below the seam). The upper ball is
 *   written at rows 20..31, the lower at 0..11, so both meet at the seam.
 *   The topmost panel row can ghost the previous slot's last row (row 31);
 *   that is a scan/panel first-row artifact, not a row-mapping error.
 *
 *   The frame is submitted once and never rewritten, so the PS cannot tear
 *   the buffer the PL is displaying. The PL keeps re-reading the same base
 *   every revolution. Start the motor after the frame is submitted; the first
 *   revolution may miss slice 0 (the reader prefetches slice 0 during the
 *   previous revolution's last slot), which is the known start-up limitation.
 *
 * HUB75_VOLUMETRIC_TEST = 0:
 *   Previous stationary 2D animation. All 64 slices are identical, so a
 *   non-rotating panel shows a stable picture for no-IR bench bring-up.
 *
 * If the upper/lower halves appear swapped, swap the rgb_upper/rgb_lower
 * arguments at the hub75_frame_set_pixel call. If the panel is column-mirrored,
 * the two balls swap left/right; the 3D shape is unaffected.
 *
 * Build: create a Vitis application from board/output/hub75_ps_stage1.xsa,
 * add hub75_frame.c/h and hub75_regs.h plus this file to the app src, build,
 * and run with Program FPGA + Reset entire system, or regenerate BOOT.BIN with
 * build/run_build_sd_boot.bat for standalone SD boot. See sw/README.md.
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

#define HUB75_VOLUMETRIC_TEST 1

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

/* Submit one completed frame. The PL stores frame_base as pending and latches
 * it at the next IR revolution boundary; frame_ctrl[0] is a toggle, not a
 * pulse. The read-back guarantees frame_base arrives before the submit bit. */
static void submit_frame(uint8_t *frame, uint32_t *toggle)
{
    Xil_DCacheFlushRange((UINTPTR)frame, HUB75_FRAME_BYTES);

    XGpio_DiscreteWrite(&gpio_ctrl, HUB75_GPIO_CH1, (uint32_t)(UINTPTR)frame);
    (void)XGpio_DiscreteRead(&gpio_ctrl, HUB75_GPIO_CH1);

    *toggle ^= 1u;
    XGpio_DiscreteWrite(&gpio_ctrl, HUB75_GPIO_CH2,
                        HUB75_CTRL_ENABLE |
                        HUB75_CTRL_SLICES(HUB75_SLICES) | *toggle);
}

#if HUB75_VOLUMETRIC_TEST

/* sin(2*pi*s/64) * 32767 for s = 0..63. cos(theta) is
 * sin_q15[(s + 16) & 63]. This keeps the renderer free of libm. */
static const int16_t sin_q15[64] = {
         0,   3212,   6393,   9512,  12539,  15446,  18204,  20787,
     23170,  25329,  27245,  28898,  30273,  31356,  32137,  32609,
     32767,  32609,  32137,  31356,  30273,  28898,  27245,  25329,
     23170,  20787,  18204,  15446,  12539,   9512,   6393,   3212,
         0,  -3212,  -6393,  -9512, -12539, -15446, -18204, -20787,
    -23170, -25329, -27245, -28898, -30273, -31356, -32137, -32609,
    -32767, -32609, -32137, -31356, -30273, -28898, -27245, -25329,
    -23170, -20787, -18204, -15446, -12539,  -9512,  -6393,  -3212
};

#define BALL_RADIUS_PX   12.0f
#define BALL_DISTANCE_PX 24.0f
#define BALL_CENTER_Y    32.0f
#define PANEL_CENTER_X   64.0f
#define BALL_R2          (BALL_RADIUS_PX * BALL_RADIUS_PX)
#define BALL_COUNT       2

typedef struct {
    float x;        /* world x, panel centre is the rotation axis */
    float z;        /* world z; 0 keeps both balls in the anchor plane  */
    uint8_t colour; /* 3-bit HUB75 colour: 1 blue, 2 green, 4 red, 7 white */
} ball_t;

static const ball_t balls[BALL_COUNT] = {
    { -BALL_DISTANCE_PX, 0.0f, 4u }, /* left: red */
    {  BALL_DISTANCE_PX, 0.0f, 2u }, /* right: green */
};

/* Render all 64 angular slices of the two-sphere volume. Each slice is the
 * intersection of the rotating panel plane with the spheres. Upper data goes
 * to rows 20..31 (above the seam), lower data to rows 0..11 (below it). */
static void render_volume(uint8_t *frame)
{
    int slice, row, col, b;

    hub75_frame_clear(frame);

    for (slice = 0; slice < HUB75_SLICES; slice++) {
        float st = (float)sin_q15[slice] / 32768.0f;
        float ct = (float)sin_q15[(slice + 16) & 63] / 32768.0f;
        float p[BALL_COUNT];
        float d2[BALL_COUNT];

        for (b = 0; b < BALL_COUNT; b++) {
            float d = balls[b].x * st - balls[b].z * ct;
            p[b]  = balls[b].x * ct + balls[b].z * st;
            d2[b] = d * d;
        }

        for (row = 0; row < HUB75_ROW_ADDRS; row++) {
            /* Normal panel row mapping: row_addr is the physical y within the
             * upper half (0 = top), and the lower half is row_addr+32. The
             * topmost row can ghost the previous slot's last upper row
             * (row 31); that is a scan/panel first-row artifact, left alone
             * for now. */
            float yu = ((float)row + 0.5f) - BALL_CENTER_Y;
            float yl = ((float)row + (float)HUB75_ROW_ADDRS + 0.5f) -
                       BALL_CENTER_Y;
            float dyu2 = yu * yu;
            float dyl2 = yl * yl;

            for (col = 0; col < HUB75_COLS; col++) {
                float rx = ((float)col + 0.5f) - PANEL_CENTER_X;
                uint8_t upper = 0u;
                uint8_t lower = 0u;

                for (b = 0; b < BALL_COUNT; b++) {
                    float dx = rx - p[b];
                    float base = dx * dx + d2[b];
                    if (base + dyu2 <= BALL_R2) upper = balls[b].colour;
                    if (base + dyl2 <= BALL_R2) lower = balls[b].colour;
                }

                if (upper != 0u || lower != 0u)
                    hub75_frame_set_pixel(frame, slice, row, col,
                                          upper, lower);
            }
        }
    }
}

#else

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

#endif

int main(void)
{
    uint8_t *frames[2] = { (uint8_t *)HUB75_FRAME_A,
                           (uint8_t *)HUB75_FRAME_B };
    uint32_t toggle = 0;

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

#if HUB75_VOLUMETRIC_TEST
    /* One static volume: render once, submit once, never touch the buffer
     * again. The PL re-reads the same base every revolution. */
    console_printf("render two-ball volume ...\r\n");
    render_volume(frames[0]);
    submit_frame(frames[0], &toggle);
    console_printf("volume submitted base %x\r\n", (unsigned)(UINTPTR)frames[0]);

    for (;;) {
        uint32_t status = status_read();
        console_printf("status %x slice %u id %u period %u\r\n",
                       status, HUB75_ST_SLICE(status),
                       HUB75_ST_FRAME_ID(status), period_read());
        usleep(1000000);
    }
#else
    uint32_t frame_no = 0;
    uint32_t last_done = 0;

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
        submit_frame(frame, &toggle);

        status = status_read();
        console_printf("frame %u base %x status %x slice %u id %u period %u\r\n",
                       frame_no, (unsigned)(UINTPTR)frame, status,
                       HUB75_ST_SLICE(status), HUB75_ST_FRAME_ID(status),
                       period_read());

        frame_no++;
        usleep(50000);
    }
#endif

    return 0;
}
