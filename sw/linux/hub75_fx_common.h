#ifndef HUB75_FX_COMMON_H
#define HUB75_FX_COMMON_H

#include <stdint.h>

/* Shared volumetric-effect framework.
 *
 * World coordinates: x,y in [-64,64), z in [-32,32), 1 unit = 1 panel pixel.
 * fx_grid[ix][iy][gz] stores one colour; z is the fastest axis so a render
 * lookup reads 64 contiguous bytes.  ix = floor(x+64), iy = floor(y+64),
 * gz = floor(31.5-z) (panel row 0 is world z = +31.5).
 */
#define FX_GX 128
#define FX_GY 128
#define FX_GZ 64
#define FX_SLICES 64
#define FX_SLICE_BYTES 3072

/* palette: bit0 blue, bit1 green, bit2 red */
#define FX_RED     4u
#define FX_GREEN   2u
#define FX_BLUE    1u
#define FX_YELLOW  6u
#define FX_CYAN    3u
#define FX_MAGENTA 5u
#define FX_WHITE   7u

extern uint8_t fx_grid[FX_GX][FX_GY][FX_GZ];

/* Optional 2D overlay: the same 128x64 image is ORed into every slice, so
 * it appears as a stable flat HUD on the rotating display (like hub75d's
 * console2d).  Used by the tunnel game for score/lives text. */
extern uint8_t fx_overlay[128 * 64];
extern int fx_overlay_enabled;

void fx_clear(void);

/* Plot a point. size 0 = one voxel, 1 = 2x2x2, 2 = 3x3x3. */
void fx_splat(float wx, float wy, float wz, uint8_t colour, int size);

uint64_t fx_ticks(void);

/* Map /dev/mem, then run build(t_ms) ~10 times/second until SIGTERM. */
int fx_run(void (*build)(uint64_t t_ms));

static inline uint32_t fx_rand(uint32_t *s)
{
    *s = (*s * 1664525u) + 1013904223u;
    return *s;
}

static inline float fx_randf(uint32_t *s)
{
    return (float)(fx_rand(s) >> 8) * (1.0f / 16777216.0f);
}

#endif
