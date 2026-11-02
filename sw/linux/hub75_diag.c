/*
 * hub75_diag - measure the PL state and exercise the submit handshake.
 *
 * This is the bring-up instrument for the Linux port. It answers three
 * questions without touching the frame contents:
 *   1. Is the scheduler timebase advancing at the expected slot rate?
 *   2. Does the PL see the AXI GPIO enable/submit bits?
 *   3. Does a submit latch a frame (frame_ack / frame_id / buf_ready) and how
 *      long does it take?
 *
 * Status word (see sw/PS_DEVELOPER_GUIDE.md):
 *   [0] frame_ack  [1] reader_busy  [2] buf_ready  [3] frame_done_toggle
 *   [4] ir_active  [5] pending_valid  [6] active_valid  [7] enable
 *   [13:8] active_slice  [23:16] frame_id
 *   [30] submit_toggle  [31] period_valid
 *
 * Build:
 *   E:\AMD\2026.1\gnu\aarch32\nt\gcc-arm-linux-gnueabi\bin\arm-linux-gnueabihf-gcc.exe \
 *       -static -O2 -o hub75_diag hub75_diag.c
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define CTRL_PHYS 0x41200000UL
#define STAT_PHYS 0x41210000UL
/* Zynq global timer (333.33 MHz). The vendor 4.14 kernel does not implement
 * the 32-bit time64 syscalls that static glibc 2.35+ clock_gettime uses, so
 * CLOCK_MONOTONIC never advances here. Reading the timer registers directly
 * through /dev/mem is independent of the kernel's time support. */
#define GT_PHYS   0xF8F00000UL
#define GT_LO_IDX ((0x200) / 4)
#define GT_HI_IDX ((0x204) / 4)
#define TICKS_PER_MS 333333ULL

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

static volatile uint32_t *gt;

static uint64_t now_ticks(void)
{
    uint32_t hi, lo, hi2;
    do {
        hi = gt[GT_HI_IDX];
        lo = gt[GT_LO_IDX];
        hi2 = gt[GT_HI_IDX];
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

static void print_status(const char *tag, uint32_t st, uint32_t period)
{
    printf("%s st=0x%08x ack=%u busy=%u buf=%u done=%u ir=%u pend=%u act=%u en=%u "
           "slice=%2u id=%3u wrap=%2u submit=%u pvalid=%u period=%u\n",
           tag, st,
           st & 1, (st >> 1) & 1, (st >> 2) & 1, (st >> 3) & 1,
           (st >> 4) & 1, (st >> 5) & 1, (st >> 6) & 1, (st >> 7) & 1,
           (st >> 8) & 0x3f, (st >> 16) & 0xff, (st >> 24) & 0x3f,
           (st >> 30) & 1, (st >> 31) & 1, period);
}

int main(void)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "open /dev/mem: %s\n", strerror(errno));
        return 1;
    }

    volatile uint32_t *ctrl = map_phys(fd, CTRL_PHYS, 4096, "ctrl");
    volatile uint32_t *stat = map_phys(fd, STAT_PHYS, 4096, "status");
    gt = map_phys(fd, GT_PHYS, 4096, "global-timer");
    if (!ctrl || !stat || !gt) return 1;

    /* Both GPIO channels are outputs on the PL side; AXI GPIO resets the
     * tri-state register to all ones, so drive them explicitly. */
    ctrl[1] = 0;
    ctrl[3] = 0;
    __sync_synchronize();

    uint32_t st = stat[0];
    uint32_t period = stat[2];   /* status ch1 = status word, ch2 = period */
    uint32_t ctrl0 = ctrl[0];
    uint32_t ctrl2 = ctrl[2];
    printf("ctrl frame_base=0x%08x frame_ctrl=0x%08x tri1=%u tri2=%u\n",
           ctrl0, ctrl2, ctrl[1], ctrl[3]);
    print_status("initial", st, period);

    /* 1. Scheduler cadence: sample active_slice for 100 ms. A healthy
     *    50 MHz / 1800 RPM timebase advances 64 slices per 33.3 ms, i.e. one
     *    step every ~521 us. Count how many steps we see and derive the slot
     *    period from the elapsed time. */
    {
        unsigned prev = (st >> 8) & 0x3f;
        unsigned steps = 0;
        uint64_t t0 = now_ticks();
        uint64_t dt;
        while ((dt = now_ticks() - t0) < 100ULL * TICKS_PER_MS) {
            uint32_t s = stat[0];
            unsigned cur = (s >> 8) & 0x3f;
            if (cur != prev) {
                steps += (cur - prev) & 0x3f;
                prev = cur;
            }
        }
        printf("scheduler: %u slice steps in %llu ticks (%.1f ms) -> %.1f us/slot "
               "(expect ~521 us at 50 MHz)\n",
               steps, (unsigned long long)dt,
               (double)dt / (double)TICKS_PER_MS,
               steps ? (double)dt / (double)steps / ((double)TICKS_PER_MS / 1000.0) : 0.0);
    }

    /* 2. Submit handshake. Flip the submit bit (bit 0) and keep enable set.
     *    The PL synchronises the toggle, latches the pending frame base and
     *    commits it on the next revolution. Poll long enough to cover the
     *    fallback revolution (33.3 ms) with margin. */
    ctrl2 = ctrl[2];
    uint32_t submit = (ctrl2 ^ 1u) | 0x2u;   /* toggle bit0, ensure enable */
    ctrl[0] = 0x42000000u;                   /* frame BRAM base */
    __sync_synchronize();
    (void)ctrl[0];
    usleep(2000);   /* base must be visible before the submit latches it */
    ctrl[2] = submit;
    __sync_synchronize();
    usleep(1000);
    if (!(stat[0] & (1u << 5))) {             /* PL rejected the submit */
        ctrl[2] = ((ctrl[2] ^ 1u) & 1u) | 0x2u;
        __sync_synchronize();
    }
    printf("submit: frame_ctrl 0x%08x -> 0x%08x (readback 0x%08x)\n",
           ctrl2, submit, ctrl[2]);

    {
        uint32_t base = stat[0];
        uint32_t ack = base & 1u, id = (base >> 16) & 0xff;
        unsigned seen_ack = 0, seen_id = 0, seen_buf = 0, seen_pend = 0, seen_act = 0;
        unsigned last_slice = (base >> 8) & 0x3f;
        uint64_t t0 = now_ticks();
        unsigned reported = 0;
        while (now_ticks() - t0 < 2000ULL * TICKS_PER_MS) {
            uint32_t s = stat[0];
            uint32_t sa = s & 1u, si = (s >> 16) & 0xff;
            unsigned sp = (s >> 5) & 1, sact = (s >> 6) & 1, sb = (s >> 2) & 1;
            unsigned cur_slice = (s >> 8) & 0x3f;
            if (sa != ack) { ack = sa; seen_ack = 1; reported |= 1; }
            if (si != id)  { id = si; seen_id = 1; reported |= 2; }
            if (sp && !seen_pend) { seen_pend = 1; reported |= 4; }
            if (sact && !seen_act) { seen_act = 1; reported |= 8; }
            if (sb && !seen_buf) { seen_buf = 1; reported |= 16; }
            if (cur_slice != last_slice) {
                last_slice = cur_slice;
            }
            if (reported) {
                print_status("change", s, stat[2]);
                reported = 0;
            }
            usleep(1000);
        }
        printf("result: seen_pending=%u seen_active=%u seen_ack=%u seen_id=%u "
               "seen_buf_ready=%u (polled 2000 ms)\n",
               seen_pend, seen_act, seen_ack, seen_id, seen_buf);
        printf("final ");
        print_status("", stat[0], stat[2]);
    }

    printf("diag done\n");
    return 0;
}
