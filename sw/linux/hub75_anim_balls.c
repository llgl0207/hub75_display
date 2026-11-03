/*
 * hub75_anim_balls - four bouncing balls in the volumetric display.
 *
 * Each ball follows an analytic parabolic bounce between the floor and a
 * per-ball apex, while slowly orbiting the vertical axis at its own radius
 * and direction.  At the moment of impact a flat ring expands on the floor,
 * so the bounce reads clearly even at the ~10 fps the 600 RPM fallback
 * latches.  Balls squash slightly at the floor.
 *
 * Frames are built into a 128x128x64 world-space voxel grid, then sampled
 * along the 64 rotating panel slices and submitted through AXI GPIO with
 * the same A/B double buffer as the other animations.
 */
#include <errno.h>
#include <fcntl.h>
#include <math.h>
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

#define GX 128
#define GY 128
#define GZ 64

#define FLOOR_Z     (-30.0f)   /* world z of the floor */
#define RING_TIME    0.32f     /* seconds a floor ring lives */
#define RING_SPEED  70.0f      /* ring radius growth, world units/s */

/*
 * radius, orbit radius, orbit rad/s, orbit phase, bounce period s,
 * bounce phase s, bounce height, colour
 */
typedef struct {
    float r;
    float orbit;
    float omega;
    float orbit_phase;
    float period;
    float bounce_phase;
    float height;
    uint8_t colour;
} ball_t;

static const ball_t balls[] = {
    { 6.0f, 24.0f,  0.90f, 0.00f, 1.15f, 0.00f, 40.0f, 4u }, /* red     */
    { 5.0f, 32.0f, -0.65f, 2.10f, 1.45f, 0.35f, 30.0f, 2u }, /* green   */
    { 5.0f, 14.0f,  1.30f, 4.20f, 0.95f, 0.70f, 46.0f, 1u }, /* blue    */
    { 4.5f, 20.0f, -1.10f, 1.00f, 1.25f, 0.15f, 36.0f, 6u }, /* yellow  */
};
#define BALL_COUNT ((int)(sizeof(balls) / sizeof(balls[0])))

static volatile uint32_t *ctrl, *statp, *gt;
static uint8_t *frames;
static volatile sig_atomic_t stop_flag;

static uint8_t grid[GX][GY][GZ];

#ifdef PROFILE
#define PROF(...) fprintf(stderr, __VA_ARGS__)
#else
#define PROF(...) do { } while (0)
#endif

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

/* Filled disc at world (wx,wy) on voxel row gz. */
static void stamp_disc(int gz, float wx, float wy, float rad, uint8_t colour)
{
    int cx = (int)floorf(wx + 64.0f);
    int cy = (int)floorf(wy + 64.0f);
    int ir = (int)ceilf(rad);
    float r2 = rad * rad;

    for (int dy = -ir; dy <= ir; dy++) {
        int iy = cy + dy;
        if (iy < 0 || iy >= GY) continue;
        float py = (float)iy - 63.5f;
        float ey = py - wy;
        for (int dx = -ir; dx <= ir; dx++) {
            int ix = cx + dx;
            float px, ex;
            if (ix < 0 || ix >= GX) continue;
            px = (float)ix - 63.5f;
            ex = px - wx;
            if (ex * ex + ey * ey <= r2)
                grid[ix][iy][gz] = colour;
        }
    }
}

/* Sphere with independent horizontal/vertical radii (for squash). */
static void stamp_ball(float wx, float wy, float wz, float rh, float rv,
                       uint8_t colour)
{
    float top = wz + rv;
    float bot = wz - rv;
    int gz0 = (int)floorf(31.5f - top);
    int gz1 = (int)ceilf(31.5f - bot);

    if (gz0 < 0) gz0 = 0;
    if (gz1 >= GZ) gz1 = GZ - 1;
    for (int gz = gz0; gz <= gz1; gz++) {
        float pz = 31.5f - (float)gz;
        float dz = (pz - wz) / rv;
        float rr;
        if (dz < -1.0f || dz > 1.0f) continue;
        rr = rh * sqrtf(1.0f - dz * dz);
        if (rr > 0.5f)
            stamp_disc(gz, wx, wy, rr, colour);
    }
}

/* Expanding impact ring on the floor. */
static void stamp_ring(float wx, float wy, float rad, uint8_t colour)
{
    int gz = (int)floorf(31.5f - (FLOOR_Z + 1.0f));
    int steps = (int)(6.2831853f * rad / 0.9f);
    if (steps < 16) steps = 16;
    if (steps > 160) steps = 160;
    if (gz < 0 || gz >= GZ) return;
    for (int i = 0; i < steps; i++) {
        float a = 6.2831853f * (float)i / (float)steps;
        stamp_disc(gz, wx + rad * cosf(a), wy + rad * sinf(a), 1.0f, colour);
    }
}

static void build_grid(uint64_t t_ms)
{
    float t = (float)t_ms * 0.001f;

    memset(grid, 0, sizeof(grid));

    for (int b = 0; b < BALL_COUNT; b++) {
        const ball_t *p = &balls[b];
        float ang = p->orbit_phase + p->omega * t;
        float bx = p->orbit * cosf(ang);
        float by = p->orbit * sinf(ang);
        float tau = fmodf(t + p->bounce_phase, p->period);
        float g = 8.0f * p->height / (p->period * p->period);
        float v0 = 4.0f * p->height / p->period;
        float zc = FLOOR_Z + p->r + v0 * tau - 0.5f * g * tau * tau;

        /* squash near the floor, bottom stays in contact */
        float d = zc - (FLOOR_Z + p->r);
        float s = 1.0f;
        float rv, rh, zdraw;
        if (d < 2.5f) {
            if (d < 0.0f) d = 0.0f;
            s = 0.72f + 0.28f * (d / 2.5f);
        }
        rv = p->r * s;
        rh = p->r * (1.0f + 0.35f * (1.0f - s));
        zdraw = zc - (p->r - rv);
        stamp_ball(bx, by, zdraw, rh, rv, p->colour);

        if (tau < RING_TIME)
            stamp_ring(bx, by, p->r + tau * RING_SPEED, p->colour);
    }
}

static void render_frame(uint8_t *frame)
{
    hub75_frame_clear(frame);
    for (int slice = 0; slice < HUB75_SLICES; slice++) {
        float ang = (float)slice * (6.28318530718f / 64.0f);
        float ct = cosf(ang), st = sinf(ang);

        for (int col = 0; col < HUB75_COLS; col++) {
            float r = (float)col - 63.5f;
            int ix = (int)floorf(r * ct + 64.0f);
            int iy = (int)floorf(r * st + 64.0f);
            if (ix < 0 || ix >= GX || iy < 0 || iy >= GY) continue;
            for (int row = 0; row < HUB75_ROW_ADDRS; row++) {
                uint8_t up = grid[ix][iy][row];
                uint8_t lo = grid[ix][iy][row + HUB75_ROW_ADDRS];
                if (up || lo)
                    hub75_frame_set_pixel(frame, slice, row, col, up, lo);
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
    uint64_t anim_t0;

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

    anim_t0 = ticks();
#ifdef PROFILE
    {
        uint64_t pb = 0, pr = 0, ps = 0;
        int pn = 0;
        for (unsigned f = 0; !stop_flag; f++) {
            uint64_t now = ticks();
            uint64_t t_ms = (now - anim_t0) / TICKS_PER_MS;
            uint8_t *dst = frames + ((f & 1) ? FRAME_SPAN : 0);
            uint64_t a0, a1, a2, a3;

            a0 = ticks();
            build_grid(t_ms);
            a1 = ticks();
            render_frame(canvas);
            a2 = ticks();
            copy_and_submit(canvas, dst, (f & 1) ? FRAME_B : FRAME_A);
            a3 = ticks();

            pb += a1 - a0; pr += a2 - a1; ps += a3 - a2;
            if (++pn == 10) {
                PROF("balls B=%lums R=%lums S=%lums\n",
                     (unsigned long)(pb / 10 / TICKS_PER_MS),
                     (unsigned long)(pr / 10 / TICKS_PER_MS),
                     (unsigned long)(ps / 10 / TICKS_PER_MS));
                pb = pr = ps = 0;
                pn = 0;
            }
            sleep_ms(30);
        }
    }
#else
    for (unsigned f = 0; !stop_flag; f++) {
        uint64_t now = ticks();
        uint64_t t_ms = (now - anim_t0) / TICKS_PER_MS;
        uint8_t *dst = frames + ((f & 1) ? FRAME_SPAN : 0);

        build_grid(t_ms);
        render_frame(canvas);
        copy_and_submit(canvas, dst, (f & 1) ? FRAME_B : FRAME_A);
        sleep_ms(30);
    }
#endif
    return 0;
}
