/*
 * hub75_fx - multicall entry for the volumetric effects.
 *
 * Usage: hub75_fx blackhole|fireworks|vortex|knot
 * The small wrapper scripts on the FAT partition (fx_blackhole etc.) invoke
 * this with the matching mode, so 3dplay can start each effect by name.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "hub75_fx_common.h"

void fx_blackhole_build(uint64_t t_ms);
void fx_fireworks_build(uint64_t t_ms);
void fx_vortex_build(uint64_t t_ms);
void fx_knot_build(uint64_t t_ms);
void fx_tunnel_build(uint64_t t_ms);

int main(int argc, char **argv)
{
    if (argc >= 2) {
        if (!strcmp(argv[1], "blackhole"))
            return fx_run(fx_blackhole_build);
        if (!strcmp(argv[1], "fireworks"))
            return fx_run(fx_fireworks_build);
        if (!strcmp(argv[1], "vortex"))
            return fx_run(fx_vortex_build);
        if (!strcmp(argv[1], "knot"))
            return fx_run(fx_knot_build);
        if (!strcmp(argv[1], "tunnel"))
            return fx_run(fx_tunnel_build);
    }
    fprintf(stderr,
            "usage: hub75_fx <blackhole|fireworks|vortex|knot|tunnel>\n");
    return 1;
}
