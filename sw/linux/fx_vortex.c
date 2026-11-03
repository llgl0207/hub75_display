/*
 * fx_vortex - fire tornado: embers spiral upward and wrap from the top back
 * to the bottom; colour by height, white at the base to red/magenta on top.
 */
#include <math.h>
#include <stdint.h>

#include "hub75_fx_common.h"

#define EMBER_N 1800
#define CORE_N  160

typedef struct {
    float r0;
    float theta0;
    float z0;
    float omega;
    float vz;
    float phase;
} ember_t;

static ember_t em[EMBER_N];
static float core_r[CORE_N], core_th[CORE_N], core_z[CORE_N];
static int inited;

static void init(void)
{
    uint32_t seed = 0x51ed270bu;

    for (int i = 0; i < EMBER_N; i++) {
        em[i].r0 = 2.0f + 24.0f * fx_randf(&seed);
        em[i].theta0 = 6.2831853f * fx_randf(&seed);
        em[i].z0 = 60.0f * fx_randf(&seed);
        em[i].omega = 0.8f + 1.1f * fx_randf(&seed);
        em[i].vz = 12.0f + 16.0f * fx_randf(&seed);
        em[i].phase = 6.2831853f * fx_randf(&seed);
    }
    for (int i = 0; i < CORE_N; i++) {
        core_r[i] = 3.0f * fx_randf(&seed);
        core_th[i] = 6.2831853f * fx_randf(&seed);
        core_z[i] = 60.0f * fx_randf(&seed);
    }
    inited = 1;
}

void fx_vortex_build(uint64_t t_ms)
{
    float t = (float)t_ms * 0.001f;

    if (!inited) init();

    for (int i = 0; i < EMBER_N; i++) {
        float z = -30.0f + fmodf(em[i].z0 + em[i].vz * t, 60.0f);
        float th = em[i].theta0 + em[i].omega * t +
                   0.30f * sinf(t * 2.0f + em[i].phase);
        float r = em[i].r0 + 2.0f * sinf(t * 1.7f + em[i].phase * 1.3f);
        float x = r * cosf(th);
        float y = r * sinf(th);
        float h = (z + 30.0f) / 60.0f;
        uint8_t c;
        int size = 0;

        if (h < 0.08f)      { c = FX_WHITE;   size = 1; }
        else if (h < 0.30f) { c = FX_YELLOW;  size = 1; }
        else if (h < 0.55f) { c = FX_YELLOW; }
        else if (h < 0.85f) { c = FX_RED; }
        else                { c = FX_MAGENTA; }
        fx_splat(x, y, z, c, size);
    }

    /* bright, flickering central column */
    for (int i = 0; i < CORE_N; i++) {
        float z = -30.0f + fmodf(core_z[i] + 24.0f * t, 60.0f);
        float th = core_th[i] + 1.4f * t;
        float r = core_r[i] * (1.0f + 0.3f * sinf(t * 5.0f + core_th[i]));
        uint8_t c = (z < -15.0f) ? FX_WHITE : FX_YELLOW;
        fx_splat(r * cosf(th), r * sinf(th), z, c, 1);
    }
}
