/*
 * bram_anim - bare-metal real-time animation through the BRAM frame path.
 *
 * The PS computes a 2D image every frame (moving colour bars), writes it into
 * one of two 192 KiB BRAM frame buffers, submits it, and waits for the PL to
 * commit it at the next synthetic revolution. Frame counters and status
 * snapshots are kept in DDR so the JTAG debugger can read them without UART.
 *
 * Frame layout matches hub75_frame.h / hub75_ddr_reader.v:
 *   64 slices, each 32 row_addr x 128 col x 6-bit word, packed LSB-first;
 *   word[2:0] = rgb1 (upper half), word[5:3] = rgb2 (lower half).
 * The 2D image is the same in all 64 slices, so it looks static in space and
 * animates in time.
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
#define STAT_PERIOD     0x41210008u

#define FRAME_A         0x42000000u
#define FRAME_B         0x42030000u   /* 192 KiB later, still inside 512 KiB BRAM */
#define SLICES          64
#define SLICE_BYTES     3072
#define FRAME_BYTES     (SLICES * SLICE_BYTES)
#define TICKS_PER_MS    333333u

static uint8_t slice_img[SLICE_BYTES];   /* one rendered slice */

volatile uint32_t dbg[32];
volatile uint32_t done_flag;

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

/* Render one slice of the moving-bar image. All slices are identical. */
static void render_slice(uint32_t f)
{
    uint32_t r, c;

    clear_bytes(slice_img, SLICE_BYTES);
    for (r = 0; r < 32; r++) {
        for (c = 0; c < 128; c++) {
            uint32_t colour = ((c + f * 4u) >> 4) & 7u;  /* 8 bars, move 4 px/frame */
            uint32_t word = colour | (colour << 3);      /* same colour upper/lower */
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

/* Write the slice image into all 64 slice slots of a BRAM frame buffer with
 * 32-bit full-width stores (the BRAM controller rejects narrow bursts). */
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

static void submit(uint32_t base)
{
    uint32_t c;

    REG32(CTRL_FRAME_BASE) = base;
    __asm__ volatile("dsb");
    spin(20000);                        /* let the base cross into the PL */
    c = REG32(CTRL_FRAME_CTRL);
    REG32(CTRL_FRAME_CTRL) = ((c ^ 1u) & 1u) | 2u;   /* toggle submit, enable */
    __asm__ volatile("dsb");
}

void main(void)
{
    uint32_t f = 0;

    REG32(SLCR_UNLOCK) = 0xDF0Du;
    __asm__ volatile("dsb");
    REG32(FPGA0_CLK_CTRL) = REG32(FPGA0_CLK_CTRL) | 1u;
    __asm__ volatile("dsb");
    spin(20000);

    REG32(CTRL_TRI1) = 0;
    REG32(CTRL_TRI2) = 0;
    __asm__ volatile("dsb");

    dbg[0] = 0;                         /* frames submitted */
    dbg[1] = 0;                         /* latches observed */
    dbg[2] = 0;                         /* submit timeouts */
    dbg[3] = (uint32_t)ticks();

    for (;;) {
        volatile uint32_t *buf = (f & 1u) ? (volatile uint32_t *)FRAME_B
                                          : (volatile uint32_t *)FRAME_A;
        uint32_t done0 = REG32(STAT_WORD) & 8u;
        uint64_t t0 = ticks();
        uint32_t latched = 0;

        render_slice(f);
        fill_frame(buf);
        submit((uint32_t)buf);
        dbg[0] = f + 1u;

        /* Wait for the PL to commit this frame at a synthetic revolution.
         * 100 ms is three fallback revolutions; if nothing happens, record
         * a timeout and continue (the next submit may still work). */
        while ((ticks() - t0) < 100ULL * TICKS_PER_MS) {
            uint32_t st = REG32(STAT_WORD);
            if ((st & 8u) != done0) {   /* frame_done_toggle changed */
                latched = 1;
                dbg[1]++;
                dbg[4] = st;
                break;
            }
        }
        if (!latched)
            dbg[2]++;
        dbg[5] = REG32(STAT_WORD);
        dbg[6] = REG32(STAT_PERIOD);
        f++;
    }
}
