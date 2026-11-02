/*
 * jtag_copy_diag - isolate the "PS frame copy while the PL reader is active"
 * hang that took down Linux (system watchdog reset) after the frame program
 * ran with an already-latched frame.
 *
 * Sequence: latch a frame, wait until the PL reader is fetching from BRAM,
 * disable the reader, wait for the PL to confirm enable=0 and busy=0, then
 * copy 192 KiB into the frame BRAM. Markers around each step let the debugger
 * pinpoint the last completed action; the PC shows where it hung.
 */
#include <stdint.h>

#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))

#define SLCR_UNLOCK     0xF8000008u
#define FPGA0_CLK_CTRL  0xF8000170u
#define FPGA_RST_CTRL   0xF8000240u

#define CTRL_FRAME_BASE 0x41200000u
#define CTRL_TRI1       0x41200004u
#define CTRL_FRAME_CTRL 0x41200008u
#define CTRL_TRI2       0x4120000Cu
#define STAT_WORD       0x41210000u
#define STAT_PERIOD     0x41210008u
#define FRAME_BASE      0x42000000u
#define FRAME_WORDS     (196608u / 4u)

volatile uint32_t result[512];
volatile uint32_t result_count;
volatile uint32_t done_flag;

static void spin(volatile uint32_t n)
{
    while (n--)
        __asm__ volatile("nop");
}

void main(void)
{
    uint32_t n = 0;
    uint32_t i, st;

    REG32(SLCR_UNLOCK) = 0xDF0Du;
    __asm__ volatile("dsb");
    REG32(FPGA0_CLK_CTRL) = REG32(FPGA0_CLK_CTRL) | 1u;
    __asm__ volatile("dsb");
    spin(20000);

    result[n++] = 0x48554237u;
    result[n++] = REG32(FPGA0_CLK_CTRL);
    result[n++] = REG32(FPGA_RST_CTRL);

    REG32(CTRL_TRI1) = 0;
    REG32(CTRL_TRI2) = 0;
    REG32(CTRL_FRAME_BASE) = FRAME_BASE;
    __asm__ volatile("dsb");

    /* Submit and wait until a revolution latches the frame and the reader
     * has both buffers (buf_ready=1). ~40 ms of slot wraps. */
    REG32(CTRL_FRAME_CTRL) = 0x3u;
    st = 0;
    for (i = 0; i < 4000000u; i++) {
        st = REG32(STAT_WORD);
        if ((st & (1u << 6)) && (st & (1u << 2)))
            break;
    }
    result[n++] = 0xC0DE0001u;      /* latched */
    result[n++] = st;
    result[n++] = i;
    result[n++] = REG32(STAT_PERIOD);

    /* Disable the reader; keep the submit bit as is (bit0=1). */
    REG32(CTRL_FRAME_CTRL) = 0x1u;
    __asm__ volatile("dsb");
    result[n++] = 0xC0DE0002u;

    /* Wait until the PL confirms enable=0 (status bit7) and idle (bit1=0). */
    st = 0;
    for (i = 0; i < 100000u; i++) {
        st = REG32(STAT_WORD);
        if (!(st & (1u << 7)) && !(st & (1u << 1)))
            break;
    }
    result[n++] = st;
    result[n++] = i;
    result[n++] = 0xC0DE0003u;

    /* Copy 192 KiB into the frame BRAM while the reader is disabled. */
    {
        volatile uint32_t *dst = (volatile uint32_t *)(uintptr_t)FRAME_BASE;
        for (i = 0; i < FRAME_WORDS; i++)
            dst[i] = 0x00000000u;
    }
    __asm__ volatile("dsb");
    result[n++] = 0xC0DE0004u;      /* copy completed */

    st = REG32(STAT_WORD);
    result[n++] = st;

    /* Re-enable and submit a second frame. */
    REG32(CTRL_FRAME_CTRL) = 0x2u;
    __asm__ volatile("dsb");
    REG32(CTRL_FRAME_CTRL) = 0x3u;
    __asm__ volatile("dsb");
    result[n++] = 0xC0DE0005u;

    for (i = 0; i < 200u; i++) {
        result[n++] = REG32(STAT_WORD);
        spin(2000);
    }
    result[n++] = REG32(STAT_WORD);
    result[n++] = REG32(STAT_PERIOD);
    result[n++] = 0xC0DE0006u;

    result_count = n;
    __asm__ volatile("dsb");
    done_flag = 0x600D600Du;
    for (;;)
        ;
}
