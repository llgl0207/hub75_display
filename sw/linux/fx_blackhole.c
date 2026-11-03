/*
 * fx_blackhole - rotating black hole: empty core, tilted accretion disk
 * with Keplerian shear, photon ring and bipolar jets.
 */
#include <math.h>
#include <stdint.h>

#include "hub75_fx_common.h"

#define DISK_N 900
#define JET_N  150
#define RING_N 160

typedef struct {
    float r;
    float theta;
    float zoff;
    float omega;
} disk_t;

static disk_t disk[DISK_N];
static float jet_phase[JET_N];
static float jet_theta[JET_N];
static int inited;

static void init(void)
{
    uint32_t seed = 0x9e3779b9u;

    for (int i = 0; i < DISK_N; i++) {
        float r = 12.0f + 36.0f * fx_randf(&seed);
        disk[i].r = r;
        disk[i].theta = 6.2831853f * fx_randf(&seed);
        disk[i].zoff = (fx_randf(&seed) - 0.5f) * 2.6f;
        disk[i].omega = 45.0f / powf(r, 1.2f);
    }
    for (int i = 0; i < JET_N; i++) {
        jet_phase[i] = fx_randf(&seed);
        jet_theta[i] = 6.2831853f * fx_randf(&seed);
    }
    inited = 1;
}

void fx_blackhole_build(uint64_t t_ms)
{
    float t = (float)t_ms * 0.001f;
    float tilt, ct, st;

    if (!inited) init();

    tilt = 0.50f + 0.06f * sinf(t * 0.11f);
    ct = cosf(tilt);
    st = sinf(tilt);

    /* photon ring in the disk plane */
    for (int i = 0; i < RING_N; i++) {
        float a = 6.2831853f * (float)i / (float)RING_N;
        float x = 10.5f * cosf(a);
        float y = 10.5f * sinf(a);
        fx_splat(x, y * ct, y * st, FX_WHITE, 1);
    }

    /* accretion disk: differential rotation shears the particle field */
    for (int i = 0; i < DISK_N; i++) {
        float r = disk[i].r;
        float a = disk[i].theta + disk[i].omega * t;
        float x = r * cosf(a);
        float y = r * sinf(a);
        float z = disk[i].zoff;
        float y2 = y * ct - z * st;
        float z2 = y * st + z * ct;
        uint8_t c;
        int size;

        if (r < 20.0f)      { c = FX_WHITE;   size = 1; }
        else if (r < 30.0f) { c = FX_YELLOW;  size = 0; }
        else if (r < 40.0f) { c = FX_RED;     size = 0; }
        else                { c = FX_MAGENTA; size = 0; }
        fx_splat(x, y2, z2, c, size);
    }

    /* bipolar jets along the world z axis */
    for (int i = 0; i < JET_N; i++) {
        float ph = fmodf(jet_phase[i] + t * 0.42f, 1.0f);
        float side = (i & 1) ? 1.0f : -1.0f;
        float z, rr, a, x, y;
        uint8_t c;

        if (ph > 0.85f) continue;
        z = side * (9.0f + ph * 22.0f);
        a = jet_theta[i] + t * 0.9f;
        rr = 2.0f + ph * 2.5f;
        x = rr * cosf(a);
        y = rr * sinf(a);
        c = (ph < 0.25f) ? FX_CYAN : FX_BLUE;
        fx_splat(x, y, z, c, 0);
    }
}
