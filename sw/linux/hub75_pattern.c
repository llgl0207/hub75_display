/*
 * hub75_pattern - write a test frame into the reserved DDR area and submit it
 * to the PL through the AXI GPIO control block.
 *
 * Run as root after booting with "mem=256M clk_ignore_unused".
 * The PL keeps re-reading the frame every revolution, so the program can exit
 * after the submit and the pattern stays on the panel.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "hub75_frame.h"

#define CTRL_PHYS 0x41200000UL
#define STAT_PHYS 0x41210000UL

static volatile uint32_t *map_phys(int fd, unsigned long phys, size_t len,
                                   const char *what)
{
    void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)phys);
    if (p == MAP_FAILED) {
        fprintf(stderr, "mmap %s @0x%lx: %s\n", what, phys, strerror(errno));
        return NULL;
    }
    return (volatile uint32_t *)p;
}

/* Zynq global timer (333.33 MHz); clock_gettime does not advance on this
 * 4.14 kernel because static glibc uses the time64 syscall. */
static uint64_t gt_ticks(volatile uint32_t *gt)
{
    uint32_t hi, lo, hi2;
    do {
        hi = gt[0x204 / 4];
        lo = gt[0x200 / 4];
        hi2 = gt[0x204 / 4];
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

int main(void)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "open /dev/mem: %s\n", strerror(errno));
        return 1;
    }

    uint8_t *frame = (uint8_t *)map_phys(fd, HUB75_FRAME_A, HUB75_FRAME_BYTES,
                                         "frame");
    volatile uint32_t *ctrl = map_phys(fd, CTRL_PHYS, 4096, "ctrl");
    volatile uint32_t *stat = map_phys(fd, STAT_PHYS, 4096, "status");
    /* Zynq global timer: clock_gettime does not advance on this 4.14 kernel. */
    volatile uint32_t *gt = map_phys(fd, 0xF8F00000UL, 4096, "global-timer");
    if (!frame || !ctrl || !stat || !gt) return 1;

    /* Render into process memory, then copy the whole frame with 32-bit
     * stores. The AXI BRAM Controller has SUPPORTS_NARROW_BURST=0; byte
     * stores (AWSIZE=0) into the BRAM can hang the GP0 path. */
    uint8_t *canvas = malloc(HUB75_FRAME_BYTES);
    if (!canvas) { perror("malloc"); return 1; }
    hub75_frame_clear(canvas);

    for (int s = 0; s < HUB75_SLICES; s++) {
        for (int r = 0; r < HUB75_ROW_ADDRS; r++) {
            for (int c = 0; c < HUB75_COLS; c++) {
                uint8_t colour;
                if (c == 0 || c == HUB75_COLS - 1 ||
                    r == 0 || r == HUB75_ROW_ADDRS - 1)
                    colour = 7;                 /* white border */
                else if (c == HUB75_COLS / 2 || r == HUB75_ROW_ADDRS / 2)
                    colour = 3;                 /* cyan crosshair */
                else
                    colour = (uint8_t)((c >> 4) & 7); /* 8 colour bars */
                hub75_frame_set_pixel(canvas, s, r, c, colour, colour);
            }
        }
    }

    /* The AXI GPIO resets with tri-state = all ones (inputs); both control
     * channels must be switched to outputs first. */
    ctrl[1] = 0;    /* ch1 tri-state */
    ctrl[3] = 0;    /* ch2 tri-state */
    __sync_synchronize();

    /* Stop the frame reader while the CPU rewrites the frame memory. The
     * reader's AXI reads and the GP0 writes contend for the same BRAM
     * controller; stopping it first avoids concurrent access deadlock.
     * Keep bit0 (submit) untouched here: bit0 is a toggle, so writing a fixed
     * 0/1 would create an extra submit edge when the previous value differs
     * from what we assume. */
    uint32_t ctrl2_prev = ctrl[2];
    ctrl[2] = ctrl2_prev & ~(1u << 1);   /* enable = 0, submit unchanged */
    __sync_synchronize();

    /* Wait until the PL confirms it saw enable=0 (status bit7) and has no
     * fetch in flight (reader_busy=0), plus one slot of margin. Without this
     * the CPU frame copy can overlap the reader's in-flight AXI read on the
     * shared GP0/BRAM path; that combination has stalled the PS long enough
     * for the system watchdog to reset the board. */
    for (int i = 0; i < 200; i++) {
        uint32_t st = stat[0];
        if (!(st & (1u << 7)) && !(st & (1u << 1)))
            break;
        usleep(1000);
    }
    usleep(2000);   /* > one 521 us slot at 50 MHz */

    /* 32-bit copy: full-width GP0 writes, supported by the 32-bit BRAM.
     * The burst is chunked and yields every 4 KiB: on this single-core vendor
     * kernel a long uninterrupted stream of strongly-ordered device writes
     * starves the watchdogd kernel thread and the SWDT resets the board a few
     * seconds later. Yielding lets the kernel and the watchdog run. */
    {
        volatile uint32_t *dst = (volatile uint32_t *)frame;
        const uint32_t *src = (const uint32_t *)canvas;
        uint64_t t0 = gt_ticks(gt);
        for (int i = 0; i < HUB75_FRAME_BYTES / 4; i++) {
            dst[i] = src[i];
            if ((i & 0x3FF) == 0x3FF)
                usleep(1000);
        }
        {
            uint64_t t1 = gt_ticks(gt);
            printf("copy: %d bytes in %llu ms (chunked)\n",
                   HUB75_FRAME_BYTES,
                   (unsigned long long)((t1 - t0) / 333333ULL));
        }
    }
    free(canvas);

    printf("pattern written to 0x%08x (%d bytes)\n", HUB75_FRAME_A,
           HUB75_FRAME_BYTES);

    ctrl[0] = HUB75_FRAME_A;    /* ch1: frame base */
    __sync_synchronize();
    (void)ctrl[0];
    /* The base and the submit are two channels of the same AXI GPIO; AXI does
     * not order writes to different addresses. Give the base write time to
     * land before the PL latches it, otherwise the reader could latch a stale
     * base (0 at boot) and read an unmapped GP0 address, wedging the bus. */
    usleep(2000);

    /* ch2: bit0 submit toggle, bit1 enable, bits[15:8] slice count.
     * Toggle bit0 against what the PL currently sees, so this is exactly one
     * submit edge no matter what state the GPIO was left in. */
    ctrl[2] = ((ctrl2_prev ^ 1u) & 1u) | (1u << 1) |
              ((uint32_t)HUB75_SLICES << 8);
    __sync_synchronize();

    /* The PL ignores a submit whose frame_base is outside the frame BRAM
     * window. If pending did not set, toggle once more (the base may have
     * arrived late). */
    usleep(1000);
    if (!(stat[0] & (1u << 5))) {
        ctrl[2] = ((ctrl[2] ^ 1u) & 1u) | (1u << 1) |
                  ((uint32_t)HUB75_SLICES << 8);
        __sync_synchronize();
    }

    printf("submitted frame_base=0x%08x ctrl2=0x%08x\n", ctrl[0], ctrl[2]);

    /* Wait (up to 1 s) for the PL to commit the pending frame at a
     * revolution. At the 1800 RPM fallback this takes <= 33 ms; if the board
     * has a live IR sensor it happens on the next optical trigger. The
     * debug bits make a stuck handshake obvious. */
    {
        uint32_t st0 = stat[0];
        unsigned ack0 = st0 & 1u, id0 = (st0 >> 16) & 0xff;
        uint32_t st = st0;
        int waited_ms = 0;
        for (; waited_ms < 1000; waited_ms += 5) {
            usleep(5000);
            st = stat[0];
            if (((st & 1u) != ack0) || (((st >> 16) & 0xff) != id0))
                break;
        }
        printf("status=0x%08x slice=%u id=%u buf_ready=%u done=%u "
               "ir=%u pend=%u act=%u en=%u submit=%u pvalid=%u waited_ms=%d\n",
               st, (st >> 8) & 0x3f, (st >> 16) & 0xff,
               (st >> 2) & 1, (st >> 3) & 1,
               (st >> 4) & 1, (st >> 5) & 1, (st >> 6) & 1, (st >> 7) & 1,
               (st >> 30) & 1, (st >> 31) & 1, waited_ms);
    }

    printf("pattern submitted; PL continues reading the frame\n");
    return 0;
}
