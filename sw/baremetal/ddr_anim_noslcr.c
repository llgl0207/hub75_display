/*
 * ddr_anim - bare-metal real-time animation through the ORIGINAL DDR/HP0 path.
 *
 * Runs in the known-good HP0 environment (committed bitstream + its ps7_init).
 * The PS renders a moving-bar 2D image every frame into DDR buffer A or B,
 * submits it through the AXI GPIO, and waits for the PL to latch it at the
 * next revolution (frame_done toggle). Caches stay off, so no cache flush is
 * needed for the PL's HP0 reads.
 *
 * Frame layout (hub75_frame.h / hub75_ddr_reader.v):
 *   64 slices x 3072 B; each slice 32 row_addr x 128 col x 6-bit words packed
 *   LSB-first; word[2:0]=rgb1 upper, word[5:3]=rgb2 lower.
 * The 2D image is identical in all 64 slices.
 *
 * Debug state in `dbg` (read with JTAG):
 *   [0] frames submitted
 *   [1] latches observed
 *   [2] timeouts
 *   [3] last status
 */
#include <stdint.h>

#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))

#define SLCR_UNLOCK     0xF8000008u
#define FPGA0_CLK_CTRL  0xF8000170u
#define GT_LO           0xF8F00200u
#define GT_HI           0xF8F00204u

#define CTRL_FRAME_BASE 0x41200000u
#define CTRL_TRI1       0x41200004u
#define CTRL_FRAME_CTRL 0x41200008u
#define CTRL_TRI2       0x4120000Cu
#define STAT_WORD       0x41210000u

#define FRAME_A         0x10000000u
#define FRAME_B         0x10200000u
#define SLICES          64
#define SLICE_BYTES     3072
#define TICKS_PER_MS    333333u

static uint8_t slice_img[SLICE_BYTES];

volatile uint32_t dbg[8];

static uint64_t ticks(void)
{
    uint32_t hi, lo, hi2;
    do {
        hi = REG32(GT_HI);
        lo = REG32(GT_LO);
        hi2 = REG32(GT_HI);
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

static void spin(volatile uint32_t n)
{
    while (n--)
        __asm__ volatile("nop");
}

static void clear_bytes(uint8_t *p, uint32_t n)
{
    while (n--)
        *p++ = 0;
}

/* Moving colour bars; all slices identical. */
static void render_slice(uint32_t f)
{
    uint32_t r, c;

    clear_bytes(slice_img, SLICE_BYTES);
    for (r = 0; r < 32; r++) {
        for (c = 0; c < 128; c++) {
            uint32_t colour = ((c + f * 4u) >> 4) & 7u;
            uint32_t word = colour | (colour << 3);
            uint32_t bitpos = (r * 128u + c) * 6u;
            uint32_t byte = bitpos >> 3;
            uint32_t shift = bitpos & 7u;
            uint32_t v = word << shift;

            slice_img[byte] |= (uint8_t)(v & 0xFFu);
            if (shift > 2u)
                slice_img[byte + 1] |= (uint8_t)((v >> 8) & 0xFFu);
        }
    }
}

static void fill_frame(volatile uint32_t *dst)
{
    const uint32_t *src = (const uint32_t *)slice_img;
    uint32_t s, i;

    for (s = 0; s < SLICES; s++) {
        volatile uint32_t *d = dst + s * (SLICE_BYTES / 4);
        for (i = 0; i < SLICE_BYTES / 4; i++)
            d[i] = src[i];
    }
}

void main(void)
{
    uint32_t f = 0;

    /* No SLCR/FCLK writes: the surrounding environment already runs the PL. */

    REG32(CTRL_TRI1) = 0;
    REG32(CTRL_TRI2) = 0;
    __asm__ volatile("dsb");
    dbg[0] = 0;
    dbg[1] = 0;
    dbg[2] = 0;

    for (;;) {
        volatile uint32_t *buf = (f & 1u) ? (volatile uint32_t *)FRAME_B
                                          : (volatile uint32_t *)FRAME_A;
        uint32_t done0 = REG32(STAT_WORD) & 8u;
        uint64_t t0;
        uint32_t latched = 0;
        uint32_t c;

        render_slice(f);
        fill_frame(buf);

        REG32(CTRL_FRAME_BASE) = (uint32_t)buf;
        __asm__ volatile("dsb");
        spin(20000);
        c = REG32(CTRL_FRAME_CTRL);
        REG32(CTRL_FRAME_CTRL) = ((c ^ 1u) & 1u) | 2u;
        __asm__ volatile("dsb");
        dbg[0] = f + 1u;

        t0 = ticks();
        while ((ticks() - t0) < 100ULL * TICKS_PER_MS) {
            uint32_t st = REG32(STAT_WORD);
            if ((st & 8u) != done0) {
                latched = 1;
                dbg[1]++;
                dbg[3] = st;
                break;
            }
        }
        if (!latched)
            dbg[2]++;
        f++;
    }
}
