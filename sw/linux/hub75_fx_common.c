/*
 * Shared framework for the volumetric effects: voxel grid, slice sampling,
 * A/B frame submit and the main loop.  Each effect only implements
 * build(t_ms), which fills fx_grid.
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

#include "hub75_fx_common.h"

#define CTRL_PHYS    0x41200000UL
#define STAT_PHYS    0x41210000UL
#define FRAME_A      0x10000000UL
#define FRAME_B      0x10200000UL
#define FRAME_SPAN   (FRAME_B - FRAME_A)
#define GT_PHYS      0xF8F00000UL
#define TICKS_PER_MS 333333ULL

uint8_t fx_grid[FX_GX][FX_GY][FX_GZ];
uint8_t fx_overlay[128 * 64];
int fx_overlay_enabled;

static volatile uint32_t *fx_ctrl, *fx_stat, *fx_gt;
static uint8_t *fx_frames;
static volatile sig_atomic_t fx_stop;
static uint8_t fx_canvas[FX_SLICES * FX_SLICE_BYTES];
static int fx_next_buf;

uint64_t fx_ticks(void)
{
    uint32_t hi, lo, hi2;
    do { hi = fx_gt[0x204 / 4]; lo = fx_gt[0x200 / 4]; hi2 = fx_gt[0x204 / 4]; }
    while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

static void fx_sleep_ms(unsigned ms)
{
    uint64_t t0 = fx_ticks();
    while ((fx_ticks() - t0) < (uint64_t)ms * TICKS_PER_MS)
        ;
}

void fx_clear(void)
{
    memset(fx_grid, 0, sizeof(fx_grid));
}

void fx_splat(float wx, float wy, float wz, uint8_t colour, int size)
{
    int ix = (int)floorf(wx + 64.0f);
    int iy = (int)floorf(wy + 64.0f);
    int gz = (int)floorf(31.5f - wz);

    for (int dz = 0; dz <= size; dz++) {
        int z = gz + dz;
        if (z < 0 || z >= FX_GZ) continue;
        for (int dy = 0; dy <= size; dy++) {
            int y = iy + dy;
            if (y < 0 || y >= FX_GY) continue;
            for (int dx = 0; dx <= size; dx++) {
                int x = ix + dx;
                if (x >= 0 && x < FX_GX)
                    fx_grid[x][y][z] = colour;
            }
        }
    }
}

/* Sample the voxel grid along all 64 rotating panel planes.
 * Each slice gets its own 3072-byte image; all 64 images are packed into
 * fx_canvas (192 KiB) exactly like the other animations. */
static void fx_pack(void)
{
    memset(fx_canvas, 0, sizeof(fx_canvas));
    for (int slice = 0; slice < FX_SLICES; slice++) {
        uint8_t *img = fx_canvas + (size_t)slice * FX_SLICE_BYTES;
        float ang = (float)slice * (6.28318530718f / 64.0f);
        float ct = cosf(ang), st = sinf(ang);

        for (int col = 0; col < 128; col++) {
            float r = (float)col - 63.5f;
            int ix = (int)floorf(r * ct + 64.0f);
            int iy = (int)floorf(r * st + 64.0f);
            if (ix < 0 || ix >= FX_GX || iy < 0 || iy >= FX_GY) continue;

            for (int row = 0; row < 32; row++) {
                uint8_t up = fx_grid[ix][iy][row];
                uint8_t lo = fx_grid[ix][iy][row + 32];
                uint8_t word;
                uint32_t bit, byte, off;
                uint16_t sh;
                if (fx_overlay_enabled) {
                    up |= fx_overlay[row * 128 + col] & 7u;
                    lo |= fx_overlay[(row + 32) * 128 + col] & 7u;
                }
                if (!(up | lo)) continue;
                word = (uint8_t)(up | (lo << 3));
                bit = (uint32_t)(row * 128 + col) * 6u;
                byte = bit >> 3;
                off = bit & 7u;
                sh = (uint16_t)word << off;
                img[byte] |= (uint8_t)(sh & 0xFFu);
                if (off > 2u)
                    img[byte + 1] |= (uint8_t)(sh >> 8);
            }
        }
    }
}

static void on_term(int sig)
{
    (void)sig;
    fx_stop = 1;
}

/* Same safe handshake as the game: never overwrite a buffer whose previous
 * submit is still pending, then wait for the PL to latch this one. */
static void fx_submit(void)
{
    uint8_t *dst;
    uint32_t id0;
    uint64_t t0;

    t0 = fx_ticks();
    while (!fx_stop && ((fx_stat[0] >> 5) & 1u) &&
           (fx_ticks() - t0) < 400ULL * TICKS_PER_MS)
        sched_yield();

    dst = fx_frames + (fx_next_buf ? FRAME_SPAN : 0);
    memcpy(dst, fx_canvas, sizeof(fx_canvas));

    fx_ctrl[0] = fx_next_buf ? FRAME_B : FRAME_A;
    __sync_synchronize();
    (void)fx_ctrl[0];
    fx_sleep_ms(2);
    fx_ctrl[2] = ((fx_ctrl[2] ^ 1u) & 1u) | 2u;
    __sync_synchronize();
    fx_sleep_ms(1);
    if (!((fx_stat[0] >> 5) & 1u)) {
        fx_ctrl[2] = ((fx_ctrl[2] ^ 1u) & 1u) | 2u;
        __sync_synchronize();
    }
    fx_next_buf ^= 1;

    id0 = (fx_stat[0] >> 16) & 0xffu;
    t0 = fx_ticks();
    while (!fx_stop && (fx_ticks() - t0) < 150ULL * TICKS_PER_MS) {
        if (((fx_stat[0] >> 16) & 0xffu) != id0)
            break;
        sched_yield();
    }
}

int fx_run(void (*build)(uint64_t t_ms))
{
    int fd;
    uint64_t t0;

    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }
    fx_ctrl = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                   CTRL_PHYS);
    fx_stat = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                   STAT_PHYS);
    fx_gt = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, GT_PHYS);
    fx_frames = mmap(NULL, FRAME_SPAN + FX_SLICES * FX_SLICE_BYTES,
                     PROT_READ | PROT_WRITE, MAP_SHARED, fd, FRAME_A);
    if (fx_ctrl == MAP_FAILED || fx_stat == MAP_FAILED || fx_gt == MAP_FAILED ||
        fx_frames == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    fx_ctrl[1] = 0;
    fx_ctrl[3] = 0;
    __sync_synchronize();

    t0 = fx_ticks();
    while (!fx_stop) {
        uint64_t t_ms = (fx_ticks() - t0) / TICKS_PER_MS;
        fx_clear();
        build(t_ms);
        fx_pack();
        fx_submit();
    }
    return 0;
}
