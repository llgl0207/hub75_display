/*
 * fx_knot - two glowing torus knots tumble and rotate in the volume.
 * The (2,3) and (2,5) curves are sampled as dots with a colour gradient
 * along the curve, and splatted as 2x2x2 blocks for a hologram-line look.
 */
#include <math.h>
#include <stdint.h>

#include "hub75_fx_common.h"

#define KNOT_SAMPLES 720

static const uint8_t palette[6] = {
    FX_CYAN, FX_WHITE, FX_GREEN, FX_YELLOW, FX_MAGENTA, FX_RED
};

void fx_knot_build(uint64_t t_ms)
{
    float t = (float)t_ms * 0.001f;
    float spin = 0.70f * t;
    float tumble = 0.35f * sinf(0.35f * t);
    float ct = cosf(tumble);
    float st = sinf(tumble);

    for (int c = 0; c < 2; c++) {
        float phase = (c == 0) ? 0.0f : 3.14159265f;
        float R = (c == 0) ? 22.0f : 25.0f;
        float a = (c == 0) ? 9.0f : 7.0f;
        int q = (c == 0) ? 3 : 5;

        for (int i = 0; i < KNOT_SAMPLES; i++) {
            float u = 6.2831853f * (float)i / (float)KNOT_SAMPLES;
            float v = 2.0f * u + spin + phase;
            float w = (float)q * u + spin * 1.3f + phase;
            float rr = R + a * cosf(w);
            float x = rr * cosf(v);
            float y = rr * sinf(v);
            float z = a * sinf(w);
            float y2 = y * ct - z * st;
            float z2 = y * st + z * ct;
            uint8_t col = palette[(i * 6 / KNOT_SAMPLES + c * 3) % 6];
            fx_splat(x, y2, z2, col, 1);
        }
    }
}
