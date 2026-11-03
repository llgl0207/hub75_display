/* Host preview of hub75_game_breakout: dumps three 128x64 RGB frames. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define main game_original_main
#include "../sw/linux/hub75_game_breakout.c"
#undef main

static const uint8_t pal[8][3] = {
    {0, 0, 0}, {0, 0, 255}, {0, 255, 0}, {0, 255, 255},
    {255, 0, 0}, {255, 0, 255}, {255, 255, 0}, {255, 255, 255}
};

static void dump(const char *path)
{
    static uint8_t rgb[W * H * 3];
    FILE *f;
    for (int i = 0; i < W * H; i++) {
        int c = canvas[i] & 7;
        rgb[i * 3 + 0] = pal[c][0];
        rgb[i * 3 + 1] = pal[c][1];
        rgb[i * 3 + 2] = pal[c][2];
    }
    f = fopen(path, "wb");
    if (!f) return;
    fwrite(rgb, 1, sizeof(rgb), f);
    fclose(f);
}

int main(void)
{
    reset_game();
    draw_scene();
    dump("build/reports/bo_ready.raw");

    state = ST_PLAY;
    score = 30;
    brick_alive[0][0] = 0;
    brick_alive[0][4] = 0;
    brick_alive[2][2] = 0;
    bricks_left = 29;
    paddle_x = 34.0f;
    ball_x = 52.0f;
    ball_y = 30.0f;
    draw_scene();
    dump("build/reports/bo_play.raw");

    state = ST_OVER;
    score = 120;
    lives = 0;
    draw_scene();
    dump("build/reports/bo_over.raw");
    return 0;
}
