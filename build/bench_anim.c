/* Host-side timing of build_grid vs render_frame for both animations.
 * Build:  gcc -O2 -I sw/common -o build/bench_anim build/bench_anim.c sw/common/hub75_frame.c -lm
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define main anim_original_main
#include "../sw/linux/hub75_anim_balls.c"
#undef main

int main(void)
{
    uint8_t *canvas = malloc(HUB75_FRAME_BYTES);
    const int N = 300;
    clock_t a, b;

    a = clock();
    for (int i = 0; i < N; i++) build_grid((uint64_t)i * 30u);
    b = clock();
    printf("balls  build: %8.2f ms/frame\n",
           (double)(b - a) * 1000.0 / CLOCKS_PER_SEC / N);

    a = clock();
    for (int i = 0; i < N; i++) render_frame(canvas);
    b = clock();
    printf("balls  render: %8.2f ms/frame\n",
           (double)(b - a) * 1000.0 / CLOCKS_PER_SEC / N);
    return 0;
}
