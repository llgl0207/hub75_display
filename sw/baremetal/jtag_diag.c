/*
 * jtag_diag - bare-metal PL bring-up instrument loaded over JTAG.
 *
 * Why this exists: the Zynq debug AHB-AP refuses PL AXI slave accesses
 * ("PL AXI slave ports access is not allowed"), so a halted CPU cannot be
 * used to poke the AXI GPIO from the debugger. CPU-executed loads/stores do
 * work. This program runs from DDR with the MMU off, exercises the PL the
 * same way the Linux driver will, and records a timeline in `result[]` that
 * the debugger reads back with mrd.
 *
 * The program does not use the BSP or any driver: everything is direct
 * register access, so it also works as a reference for the register sequence.
 *
 * Result layout (all 32-bit words):
 *   [0]  0x48554237 magic
 *   [1]  FPGA0_CLK_CTRL before (expect 0x00400500, CLKACT0=0)
 *   [2]  FPGA0_CLK_CTRL after setting CLKACT0
 *   [3]  FPGA_RST_CTRL
 *   [4]  frame_base readback (expect 0x42000000)
 *   [5]  frame_ctrl readback before submit
 *   [6]  status before submit
 *   [7]  period before submit
 *   [8..8+2*NCAD-1] cadence samples: {status, timer_lo}
 *   [..] frame_ctrl after submit
 *   [..] {status, timer_lo} poll samples after submit
 *   last: done flag = 0x600D600D
 */
#include <stdint.h>

#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))

#define SLCR_UNLOCK     0xF8000008u
#define FPGA0_CLK_CTRL  0xF8000170u
#define FPGA_RST_CTRL   0xF8000240u
#define GLOB_TIMER_LO   0xF8F00200u
#define GLOB_TIMER_HI   0xF8F00204u

#define CTRL_BASE       0x41200000u
#define CTRL_FRAME_BASE (CTRL_BASE + 0x0u)
#define CTRL_FRAME_CTRL (CTRL_BASE + 0x8u)
#define CTRL_TRI1       (CTRL_BASE + 0x4u)
#define CTRL_TRI2       (CTRL_BASE + 0xCu)
#define STAT_BASE       0x41210000u
#define STAT_WORD       (STAT_BASE + 0x0u)
#define STAT_PERIOD     (STAT_BASE + 0x8u)
#define FRAME_BASE      0x42000000u

#define NCAD  200
#define NPOLL 800

volatile uint32_t result[64 + 2 * NCAD + 2 * NPOLL + 8];
volatile uint32_t result_count;
volatile uint32_t done_flag;

static uint32_t timer_lo(void)
{
    return REG32(GLOB_TIMER_LO);
}

static void spin(volatile uint32_t n)
{
    while (n--)
        __asm__ volatile("nop");
}

void main(void)
{
    uint32_t n = 0;
    uint32_t i;

    /* SLCR writes are locked until the unlock key is written. */
    REG32(SLCR_UNLOCK) = 0xDF0Du;
    __asm__ volatile("dsb");

    result[n++] = 0x48554237u;
    result[n++] = REG32(FPGA0_CLK_CTRL);
    REG32(FPGA0_CLK_CTRL) = REG32(FPGA0_CLK_CTRL) | 1u;  /* CLKACT0 */
    __asm__ volatile("dsb");
    result[n++] = REG32(FPGA0_CLK_CTRL);
    result[n++] = REG32(FPGA_RST_CTRL);
    /* Give the PL's proc_sys_reset time to release peripheral_aresetn. */
    spin(20000);

    /* AXI GPIO: AXI GPIO resets with tri-state all ones. */
    REG32(CTRL_TRI1) = 0;
    REG32(CTRL_TRI2) = 0;
    REG32(CTRL_FRAME_BASE) = FRAME_BASE;
    __asm__ volatile("dsb");

    result[n++] = REG32(CTRL_FRAME_BASE);
    result[n++] = REG32(CTRL_FRAME_CTRL);
    result[n++] = REG32(STAT_WORD);
    result[n++] = REG32(STAT_PERIOD);

    /* Cadence: status + timer, ~50 us apart, 200 samples (~10 ms). */
    for (i = 0; i < NCAD; i++) {
        result[n++] = REG32(STAT_WORD);
        result[n++] = timer_lo();
        spin(2000);
    }

    /* One submit edge: toggle bit0, keep enable set. */
    {
        uint32_t c2 = REG32(CTRL_FRAME_CTRL);
        REG32(CTRL_FRAME_CTRL) = (c2 ^ 1u) | 2u;
        __asm__ volatile("dsb");
        result[n++] = REG32(CTRL_FRAME_CTRL);
    }

    /* Poll: status + timer, ~50 us apart, 800 samples (~40 ms nominal,
     * much longer wall-clock here; the timer makes it measurable). */
    for (i = 0; i < NPOLL; i++) {
        result[n++] = REG32(STAT_WORD);
        result[n++] = timer_lo();
        spin(20000);
    }

    result[n++] = REG32(STAT_WORD);
    result[n++] = REG32(STAT_PERIOD);
    result_count = n;
    __asm__ volatile("dsb");
    done_flag = 0x600D600Du;

    for (;;)
        ;
}
