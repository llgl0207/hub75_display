#ifndef HUB75_FRAME_H
#define HUB75_FRAME_H

#include <stdint.h>

/* Frame layout understood by src/hub75_ddr_reader.v and hub75_scan.v:
 *
 *   slice -> 32 row addresses -> 128 columns -> one 6-bit word
 *   word[2:0] = rgb1 (upper half), word[5:3] = rgb2 (lower half)
 *   6-bit words are packed LSB-first into 3072 bytes per slice.
 *
 * The scan shifts out column 127 first, so the renderer stores panel column
 * x at col=x exactly as the PL-only pattern does.
 */
#define HUB75_SLICES       64
#define HUB75_ROW_ADDRS    32
#define HUB75_COLS         128
#define HUB75_ROWS         64
#define HUB75_SLICE_BYTES  3072
#define HUB75_FRAME_BYTES  (HUB75_SLICES * HUB75_SLICE_BYTES)

/* 2 MiB apart, outside the application's low-DDR linker regions. The Linux
 * bring-up overrides these with -DHUB75_FRAME_A=0x42000000u to target the PL
 * BRAM frame buffer instead of PS DDR. */
#ifndef HUB75_FRAME_A
#define HUB75_FRAME_A      0x10000000u
#endif
#ifndef HUB75_FRAME_B
#define HUB75_FRAME_B      0x10200000u
#endif

void hub75_frame_clear(uint8_t *frame);
void hub75_frame_set_pixel(uint8_t *frame, int slice, int row_addr, int col,
                           uint8_t rgb_upper, uint8_t rgb_lower);

#endif
