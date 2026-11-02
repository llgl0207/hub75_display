/*
 * jtag_zero_base - prove what happens when the PL reader is given an
 * unmapped GP0 address (frame_base = 0).
 *
 * Sequence: submit with frame_base=0. The bench revolution latches base 0 and
 * the reader issues its AXI read to 0x00000000, which is not in the PL
 * interconnect address map (only 0x4120_0000 and 0x4200_0000 are). If that
 * read wedges the AXI fabric, the next status read stalls and the watchdog
 * resets Linux.
 *
 * Markers in result[]:
 *   0x48554237 magic
 *   0xC0DE0001 about to submit
 *   0xC0DE0002 submitted
 *   {status, timer} samples
 *   0xC0DE0003 finished (only if the bus never wedged)
 */
#include <stdint.h>

#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))

#define SLCR_UNLOCK     0xF8000008u
#define FPGA0_CLK_CTRL  0xF8000170u
#define GLOB_TIMER_LO   0xF8F00200u

#define CTRL_FRAME_BASE 0x41200000u
#define CTRL_TRI1       0x41200004u
#define CTRL_FRAME_CTRL 0x41200008u
#define CTRL_TRI2       0x4120000Cu
#define STAT_WORD       0x41210000u

volatile uint32_t result[1024];
volatile uint32_t result_count;
volatile uint32_t done_flag;

static void spin(volatile uint32_t n)
{
    while (n--)
        __asm__ volatile("nop");
}

static uint32_t tlo(void)
{
    return REG32(GLOB_TIMER_LO);
}

void main(void)
{
    uint32_t n = 0, i, st;

    REG32(SLCR_UNLOCK) = 0xDF0Du;
    __asm__ volatile("dsb");
    REG32(FPGA0_CLK_CTRL) = REG32(FPGA0_CLK_CTRL) | 1u;
    __asm__ volatile("dsb");
    spin(20000);

    result[n++] = 0x48554237u;
    REG32(CTRL_TRI1) = 0;
    REG32(CTRL_TRI2) = 0;
    REG32(CTRL_FRAME_BASE) = 0x00000000u;   /* deliberately unmapped */
    __asm__ volatile("dsb");
    result[n++] = REG32(CTRL_FRAME_BASE);
    result[n++] = 0xC0DE0001u;

    REG32(CTRL_FRAME_CTRL) = 0x3u;          /* enable + submit */
    __asm__ volatile("dsb");
    result[n++] = 0xC0DE0002u;

    /* ~1 s of status sampling across many revolutions. If the reader's read
     * to 0 wedges the GP0 fabric, the first status read here never returns. */
    for (i = 0; i < 2000u; i++) {
        st = REG32(STAT_WORD);
        if ((i % 10u) == 0u) {
            result[n++] = st;
            result[n++] = tlo();
        }
        spin(5000);
    }
    result[n++] = 0xC0DE0003u;
    result_count = n;
    __asm__ volatile("dsb");
    done_flag = 0x600D600Du;
    for (;;)
        ;
}
