#include "hub75_frame.h"

/* Write one 6-bit word at bit position idx*6, LSB-first. */
static void set_word(uint8_t *slice, int idx, uint8_t word)
{
    uint32_t bit = (uint32_t)idx * 6u;
    uint32_t byte = bit >> 3;
    uint32_t off = bit & 7u;
    uint16_t shifted = (uint16_t)word << off;

    slice[byte] = (uint8_t)((slice[byte] & (uint8_t)~(0x3Fu << off)) |
                            (uint8_t)(shifted & 0xFFu));
    if (off > 2u) {
        slice[byte + 1] =
            (uint8_t)((slice[byte + 1] &
                       (uint8_t)~((0x3Fu << off) >> 8)) |
                      (uint8_t)(shifted >> 8));
    }
}

void hub75_frame_clear(uint8_t *frame)
{
    int i;
    for (i = 0; i < HUB75_FRAME_BYTES; i++)
        frame[i] = 0;
}

void hub75_frame_set_pixel(uint8_t *frame, int slice, int row_addr, int col,
                           uint8_t rgb_upper, uint8_t rgb_lower)
{
    uint8_t *s = frame + (uint32_t)slice * HUB75_SLICE_BYTES;
    int idx = row_addr * HUB75_COLS + col;
    uint8_t word = (uint8_t)((rgb_upper & 7u) | ((rgb_lower & 7u) << 3));
    set_word(s, idx, word);
}
