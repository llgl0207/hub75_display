/*
 * fx_fireworks - continuous fountain plus staggered rocket bursts.
 *
 * Everything is analytic in t, so the effect is frame-rate independent:
 * a rocket rises for t_apex = vz/g, then its pre-computed particle shell
 * expands and falls; colour stages white -> yellow -> burst colour -> red.
 */
#include <math.h>
#include <stdint.h>

#include "hub75_fx_common.h"

#define FW_N        8
#define BURST_N     240
#define FOUNT_N     220
#define FW_PERIOD   9.0f
#define GRAV        40.0f
#define BURST_LIFE  1.6f

typedef struct {
    float offset;
    float x0, y0;
    float vz;
    float apex;
    uint8_t base;
    float bvx[BURST_N], bvy[BURST_N], bvz[BURST_N];
} fw_t;

static fw_t fw[FW_N];
static float fvx[FOUNT_N], fvy[FOUNT_N], fvz[FOUNT_N], foff[FOUNT_N];
static int inited;

static const uint8_t palette[6] = {
    FX_RED, FX_YELLOW, FX_GREEN, FX_CYAN, FX_MAGENTA, FX_WHITE
};

static void init(void)
{
    uint32_t seed = 0x1f3d5b79u;

    for (int i = 0; i < FW_N; i++) {
        fw[i].offset = (float)i * 1.1f;
        fw[i].x0 = (fx_randf(&seed) - 0.5f) * 50.0f;
        fw[i].y0 = (fx_randf(&seed) - 0.5f) * 50.0f;
        fw[i].vz = 38.0f + 8.0f * fx_randf(&seed);
        fw[i].apex = fw[i].vz / GRAV;
        fw[i].base = palette[i % 6];
        for (int j = 0; j < BURST_N; j++) {
            float u = 2.0f * fx_randf(&seed) - 1.0f;
            float th = 6.2831853f * fx_randf(&seed);
            float sp = 18.0f + 16.0f * fx_randf(&seed);
            float rr = sqrtf(1.0f - u * u);
            fw[i].bvx[j] = rr * cosf(th) * sp;
            fw[i].bvy[j] = rr * sinf(th) * sp;
            fw[i].bvz[j] = u * sp;
        }
    }
    for (int i = 0; i < FOUNT_N; i++) {
        fvx[i] = (fx_randf(&seed) - 0.5f) * 14.0f;
        fvy[i] = (fx_randf(&seed) - 0.5f) * 14.0f;
        fvz[i] = 30.0f + 18.0f * fx_randf(&seed);
        foff[i] = fx_randf(&seed) * 1.9f;
    }
    inited = 1;
}

void fx_fireworks_build(uint64_t t_ms)
{
    float t = (float)t_ms * 0.001f;

    if (!inited) init();

    /* fountain from the centre of the floor */
    for (int i = 0; i < FOUNT_N; i++) {
        float tau = fmodf(t + foff[i], 1.9f);
        float z = -28.0f + fvz[i] * tau - 0.5f * GRAV * tau * tau;
        float x = fvx[i] * tau;
        float y = fvy[i] * tau;
        uint8_t c;
        if (z < -31.0f) continue;
        c = (tau < 0.15f) ? FX_WHITE : (tau < 0.55f) ? FX_YELLOW : FX_RED;
        fx_splat(x, y, z, c, tau < 0.5f ? 1 : 0);
    }

    /* rockets and bursts */
    for (int i = 0; i < FW_N; i++) {
        float ph = fmodf(t + fw[i].offset, FW_PERIOD);
        float apex = fw[i].apex;

        if (ph < apex) {
            float z = -28.0f + fw[i].vz * ph - 0.5f * GRAV * ph * ph;
            fx_splat(fw[i].x0, fw[i].y0, z, FX_WHITE, 1);
            for (int k = 1; k <= 5; k++) {
                float tk = ph - 0.03f * (float)k;
                if (tk <= 0.0f) break;
                z = -28.0f + fw[i].vz * tk - 0.5f * GRAV * tk * tk;
                fx_splat(fw[i].x0, fw[i].y0, z,
                         (k < 3) ? FX_YELLOW : FX_RED, 0);
            }
        } else if (ph < apex + BURST_LIFE) {
            float tau = ph - apex;
            float z0 = -28.0f + fw[i].vz * apex - 0.5f * GRAV * apex * apex;
            uint8_t c;
            if (tau < 0.12f)      c = FX_WHITE;
            else if (tau < 0.45f) c = FX_YELLOW;
            else if (tau < 0.95f) c = fw[i].base;
            else                  c = FX_RED;
            for (int j = 0; j < BURST_N; j++) {
                float x = fw[i].x0 + fw[i].bvx[j] * tau;
                float y = fw[i].y0 + fw[i].bvy[j] * tau;
                float z = z0 + fw[i].bvz[j] * tau -
                          0.5f * GRAV * tau * tau;
                fx_splat(x, y, z, c, tau < 0.5f ? 1 : 0);
            }
        }
    }
}
