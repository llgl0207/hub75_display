/*
 * hub75_anim_spheres - the classic two-ball volumetric test on Linux.
 *
 * Left sphere: world x = -24, radius 12, red.  Right sphere: x = +24,
 * radius 12, green.  Both are centred at panel y = 32 and lie in the
 * anchor plane, so physically rotating the display shows the 3D shape.
 *
 * Each of the 64 rotating panel planes is the intersection of the plane
 * with both spheres; the upper half writes rows 0..31 and the lower half
 * rows 32..63 through the 6-bit packed frame format.  The frame is written
 * to DDR (A/B window) and submitted through the AXI GPIO block; the PL
 * latches it at the next revolution and reads it over S_AXI_HP0.
 *
 * Started by hub75d ("hub75-play spheres") or by hand; exits on
 * SIGTERM/SIGINT.  Timing uses the Zynq global timer (the vendor 4.14
 * kernel has no time64 syscalls for the Vitis static glibc).
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

#define PANEL_CENTER_X   64.0f
#define BALL_RADIUS_PX   12.0f
#define BALL_DISTANCE_PX 24.0f
#define BALL_CENTER_Y    32.0f
#define BALL_R2          (BALL_RADIUS_PX * BALL_RADIUS_PX)
#define BALL_COUNT       2

typedef struct {
    float x;        /* world x, panel centre is the rotation axis */
    float z;        /* world z; 0 keeps both balls in the anchor plane */
    uint8_t colour; /* HUB75 colour: 1 blue, 2 green, 4 red, 7 white */
} ball_t;

static const ball_t balls[BALL_COUNT] = {
    { -BALL_DISTANCE_PX, 0.0f, 4u }, /* left: red */
    {  BALL_DISTANCE_PX, 0.0f, 2u }, /* right: green */
};

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

static void render_spheres(uint8_t *frame)
{
    hub75_frame_clear(frame);

    for (int slice = 0; slice < HUB75_SLICES; slice++) {
        float st = (float)sin_q15[slice] / 32768.0f;
        float ct = (float)sin_q15[(slice + 16) & 63] / 32768.0f;
        float p[BALL_COUNT];
        float d2[BALL_COUNT];

        for (int b = 0; b < BALL_COUNT; b++) {
            float d = balls[b].x * st - balls[b].z * ct;
            p[b]  = balls[b].x * ct + balls[b].z * st;
            d2[b] = d * d;
        }

        for (int row = 0; row < HUB75_ROW_ADDRS; row++) {
            float yu = ((float)row + 0.5f) - BALL_CENTER_Y;
            float yl = ((float)row + (float)HUB75_ROW_ADDRS + 0.5f) -
                       BALL_CENTER_Y;
            float dyu2 = yu * yu;
            float dyl2 = yl * yl;

            for (int col = 0; col < HUB75_COLS; col++) {
                float rx = ((float)col + 0.5f) - PANEL_CENTER_X;
                uint8_t upper = 0u;
                uint8_t lower = 0u;

                for (int b = 0; b < BALL_COUNT; b++) {
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

    /* Static volume: render once, submit once; the PL keeps scanning the
     * latched buffer every revolution.  Stay alive so hub75d keeps the
     * console off the panel until the user stops the animation. */
    render_spheres(canvas);
    copy_and_submit(canvas, frames, FRAME_A);

    while (!stop_flag)
        sleep_ms(200);

    return 0;
}
