/* Host preview harness for the fx_* effects.
 * Build with:
 *   gcc -O2 -DO_SYNC=0 -DO_NONBLOCK=0 -I build/hoststub -I sw/linux \
 *       -DFX_SRC='"../sw/linux/fx_blackhole.c"' \
 *       -DFX_BUILD_FN=fx_blackhole_build \
 *       -o build/preview_fx build/preview_fx.c sw/linux/hub75_fx_common.c -lm
 * Add -DFX_AUTOSTART for fx_tunnel (injects a click before the 2nd frame).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define main fx_original_main
#include FX_SRC
#undef main

static const uint8_t pal[8][3] = {
    {0, 0, 0}, {0, 0, 255}, {0, 255, 0}, {0, 255, 255},
    {255, 0, 0}, {255, 0, 255}, {255, 255, 0}, {255, 255, 255}
};

static void write_frame(const char *path)
{
    static uint8_t rgb[FX_GX * 64 * 3];
    FILE *f;

    for (int gz = 0; gz < 64; gz++) {
        for (int ix = 0; ix < FX_GX; ix++) {
            int best = -1;
            int col = 0;
            for (int iy = 0; iy < FX_GY; iy++) {
                int c = fx_grid[ix][iy][gz];
                if (c && (best < 0 || iy < best)) {
                    best = iy;
                    col = c & 7;
                }
            }
            if (fx_overlay_enabled)
                col |= fx_overlay[gz * FX_GX + ix] & 7;
            int o = (gz * FX_GX + ix) * 3;
            rgb[o + 0] = pal[col][0];
            rgb[o + 1] = pal[col][1];
            rgb[o + 2] = pal[col][2];
        }
    }
    f = fopen(path, "wb");
    if (!f) return;
    fwrite(rgb, 1, sizeof(rgb), f);
    fclose(f);
}

static void render(const char *path, float t)
{
    fx_clear();
    FX_BUILD_FN((uint64_t)(t * 1000.0f));
    write_frame(path);
}

int main(int argc, char **argv)
{
    float t0 = (argc > 1) ? (float)atof(argv[1]) : 0.0f;
    float t1 = (argc > 2) ? (float)atof(argv[2]) : 1.0f;
    float t2 = (argc > 3) ? (float)atof(argv[3]) : 2.0f;

    render("build/reports/fx0.raw", t0);
#ifdef FX_AUTOSTART
    start_pending = 1;
#endif
    render("build/reports/fx1.raw", t1);
    render("build/reports/fx2.raw", t2);
    return 0;
}
