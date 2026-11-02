/*
 * hub75_anim_heart - standalone 3D heart animation for the rotating display.
 *
 * Runs on the Linux/HP0 path: renders the classic heart implicit surface on
 * each of the 64 rotating panel planes, with a slow pulse, into a DDR A/B
 * double buffer and submits it through the AXI GPIO block. The PL latches the
 * pending frame at the next revolution and reads it over S_AXI_HP0.
 *
 * Started by hub75d ("mode anim /path/hub75_anim_heart") or by hand; exits on
 * SIGTERM/SIGINT (hub75d sends SIGTERM when switching back to console mode).
 *
 * NOTE: no clock_gettime/select/nanosleep. The Vitis static glibc is a
 * 64-bit-time_t build and those syscalls return ENOSYS on the vendor 4.14
 * kernel. Timing uses the Zynq global timer; yields use sched_yield().
 */
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "hub75_frame.h"

#define CTRL_PHYS   0x41200000UL
#define STAT_PHYS   0x41210000UL
#define FRAME_A     0x10000000UL
#define FRAME_B     0x10200000UL
#define FRAME_SPAN  (FRAME_B - FRAME_A)
#define GT_PHYS     0xF8F00000UL
#define TICKS_PER_MS 333333ULL

static volatile uint32_t *ctrl, *statp, *gt;
static uint8_t *frames;
static volatile sig_atomic_t stop_flag;

/* sin(2*pi*s/64) * 32767 */
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

#define PANEL_CENTER_X 64.0f
#define HEART_XS       26.0f
#define HEART_YS       18.0f
#define HEART_ZS       20.0f
#define HEART_CENTER_Y 32.0f

static uint64_t ticks(void)
{
    uint32_t hi, lo, hi2;
    do { hi = gt[0x204 / 4]; lo = gt[0x200 / 4]; hi2 = gt[0x204 / 4]; }
    while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

static void sleep_ms(unsigned ms)
{
    uint64_t t0 = ticks();
    while ((ticks() - t0) < (uint64_t)ms * TICKS_PER_MS)
        ;
}

static uint8_t heart_colour(float x, float depth, float z)
{
    float xx = x * x;
    float yy = depth * depth;
    float zz = z * z;
    float a = xx + 2.25f * yy + zz - 1.0f;
    float f = a * a * a - xx * z * z * z - 0.1125f * yy * z * z * z;

    if (f > 0.0f) return 0u;
    if (f > -0.02f) return 7u;
    if (z > 0.40f) return 5u;
    return 4u;
}

static void render_heart(uint8_t *frame, float scale)
{
    float xs = HEART_XS * scale;
    float ys = HEART_YS * scale;
    float zs = HEART_ZS * scale;

    hub75_frame_clear(frame);
    for (int slice = 0; slice < HUB75_SLICES; slice++) {
        float st = (float)sin_q15[slice] / 32768.0f;
        float ct = (float)sin_q15[(slice + 16) & 63] / 32768.0f;
        for (int row = 0; row < HUB75_ROW_ADDRS; row++) {
            float yu = (float)row + 0.5f;
            float yl = (float)row + (float)HUB75_ROW_ADDRS + 0.5f;
            float zu = (HEART_CENTER_Y - yu) / zs;
            float zl = (HEART_CENTER_Y - yl) / zs;
            for (int col = 0; col < HUB75_COLS; col++) {
                float r = ((float)col + 0.5f) - PANEL_CENTER_X;
                float x = (r * ct) / xs;
                float depth = (r * st) / ys;
                uint8_t upper = heart_colour(x, depth, zu);
                uint8_t lower = heart_colour(x, depth, zl);
                if (upper != 0u || lower != 0u)
                    hub75_frame_set_pixel(frame, slice, row, col, upper, lower);
            }
        }
    }
}

static void on_term(int sig)
{
    (void)sig;
    stop_flag = 1;
}

static void copy_and_submit(const uint8_t *canvas, uint8_t *dst, uint32_t phys_base)
{
    volatile uint32_t *d = (volatile uint32_t *)dst;
    const uint32_t *s = (const uint32_t *)canvas;
    uint32_t id0;

    for (int i = 0; i < HUB75_FRAME_BYTES / 4; i++) {
        d[i] = s[i];
        if ((i & 0x1FFF) == 0x1FFF)
            sched_yield();
    }
    ctrl[0] = phys_base;
    __sync_synchronize();
    (void)ctrl[0];
    sleep_ms(2);
    ctrl[2] = ((ctrl[2] ^ 1u) & 1u) | 2u;
    __sync_synchronize();
    sleep_ms(1);
    if (!((statp[0] >> 5) & 1u)) {
        ctrl[2] = ((ctrl[2] ^ 1u) & 1u) | 2u;
        __sync_synchronize();
    }
    id0 = (statp[0] >> 16) & 0xff;
    {
        uint64_t t0 = ticks();
        while (!stop_flag && (ticks() - t0) < 100ULL * TICKS_PER_MS) {
            if (((statp[0] >> 16) & 0xff) != id0)
                break;
            sched_yield();
        }
    }
}

int main(void)
{
    int fd;
    uint8_t *canvas;

    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    ctrl = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, CTRL_PHYS);
    statp = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, STAT_PHYS);
    gt = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, GT_PHYS);
    frames = mmap(NULL, FRAME_SPAN + HUB75_FRAME_BYTES, PROT_READ | PROT_WRITE,
                  MAP_SHARED, fd, FRAME_A);
    if (ctrl == MAP_FAILED || statp == MAP_FAILED || gt == MAP_FAILED ||
        frames == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    ctrl[1] = 0;
    ctrl[3] = 0;
    __sync_synchronize();

    canvas = malloc(HUB75_FRAME_BYTES);
    if (!canvas) { perror("malloc"); return 1; }

    for (unsigned f = 0; !stop_flag; f++) {
        float scale = 1.0f + 0.08f * ((float)sin_q15[f & 63] / 32768.0f);
        uint8_t *dst = frames + ((f & 1) ? FRAME_SPAN : 0);
        render_heart(canvas, scale);
        copy_and_submit(canvas, dst, (f & 1) ? FRAME_B : FRAME_A);
        sleep_ms(30);
    }
    return 0;
}
