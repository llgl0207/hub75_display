/*
 * hub75_anim_helix - rotating DNA double helix for the volumetric display.
 *
 * A real animation, not a static volume: the two strands spin around the
 * vertical axis and the whole helix bobs slowly up and down.  The shape is
 * built once per frame into a 128x128x64 voxel grid (world units), then each
 * of the 64 rotating panel slices is rendered by sampling that grid, packed
 * into the 6-bit HUB75 frame and submitted through the AXI GPIO block.
 *
 * Strand A is red, strand B cyan, the cross rungs white.  Timing uses the
 * Zynq global timer (the vendor 4.14 kernel has no time64 syscalls for the
 * Vitis static glibc); no clock_gettime/usleep/select.
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

/* World-space voxel grid: x,y in [-64,64), z in [-32,32). */
#define GX 128
#define GY 128
#define GZ 64

/* Helix geometry (world units; 1 unit = 1 panel pixel). */
#define HELIX_R      24.0f
#define TUBE_R        3.2f
#define PITCH         0.30f      /* rad per z unit -> ~3 turns over 64 rows */
#define RUNG_STEP     6          /* one cross rung every 6 rows */
#define RUNG_R        1.6f
#define RUNG_SAMPLES  24

/* Colours (bit0 blue, bit1 green, bit2 red). */
#define COL_A 4u   /* red   */
#define COL_B 3u   /* cyan  */
#define COL_R 7u   /* white */

static volatile uint32_t *ctrl, *statp, *gt;
static uint8_t *frames;
static volatile sig_atomic_t stop_flag;

/* z is the fastest-varying axis: a render lookup reads 64 contiguous bytes. */
static uint8_t grid[GX][GY][GZ];

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

/* Stamp a filled disc of radius rad at world (wx,wy) on row gz. */
static void stamp(int gz, float wx, float wy, float rad, uint8_t colour)
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

/* Build the helix into the voxel grid for animation time t (milliseconds). */
static void build_grid(uint64_t t_ms)
{
    float t = (float)t_ms * 0.001f;
    float phase = t * 1.6f;              /* spin, rad/s */
    float zoff = 2.0f * sinf(t * 1.1f);  /* slow vertical bob */

    memset(grid, 0, sizeof(grid));

    for (int gz = 0; gz < GZ; gz++) {
        float zw = 31.5f - (float)gz;
        float a = PITCH * (zw - zoff) + phase;
        float c = cosf(a), s = sinf(a);
        float x1 = HELIX_R * c, y1 = HELIX_R * s;

        stamp(gz,  x1,  y1, TUBE_R, COL_A);
        stamp(gz, -x1, -y1, TUBE_R, COL_B);

        if (gz % RUNG_STEP == 3) {
            for (int i = 0; i <= RUNG_SAMPLES; i++) {
                float u = (float)i / (float)RUNG_SAMPLES;
                stamp(gz, x1 * (1.0f - 2.0f * u),
                          y1 * (1.0f - 2.0f * u), RUNG_R, COL_R);
            }
        }
    }
}

/* Sample the voxel grid along all 64 panel planes into the packed frame. */
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
    for (unsigned f = 0; !stop_flag; f++) {
        uint64_t now = ticks();
        uint64_t t_ms = (now - anim_t0) / TICKS_PER_MS;
        uint8_t *dst = frames + ((f & 1) ? FRAME_SPAN : 0);

        build_grid(t_ms);
        render_frame(canvas);
        copy_and_submit(canvas, dst, (f & 1) ? FRAME_B : FRAME_A);
        sleep_ms(30);
    }
    return 0;
}
