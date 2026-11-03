#!/usr/bin/env python3
"""Generate a 64-slice boot splash frame for the HUB75 volume display.

The frame uses the PL frame format: 64 slices x 3072 bytes; each slice is
32 row addresses x 128 columns x a 6-bit word (bits 2:0 = upper half RGB,
bits 5:3 = lower half RGB), packed LSB-first.  The same 128x64 image is
written to every slice, so the panel shows a stable 2D picture (and a
cylinder of text when the display rotates).

U-Boot loads this file to 0x10000000 and submits it through the AXI GPIO
before booting Linux (see uEnv.txt uenvcmd).

Usage: python build/gen_boot_frame.py [out.frm]
"""
import re
import sys

FONT = "sw/linux/hub75_font.h"
OUT = sys.argv[1] if len(sys.argv) > 1 else "build/work/vendor_linux/hub75_boot.frm"

# ---- 8x16 font (ASCII 32..126, row-major, bit7 = leftmost pixel) ----
text = open(FONT, "r", encoding="ascii").read()
font = {}
for val, num in re.findall(r"\{([^{}]*)\}, /\* (\d+) \*/", text):
    font[int(num)] = [int(v, 16) for v in val.split(",")]

W, H = 128, 64
img = [[0] * W for _ in range(H)]


def put_text(x, y, s, rgb):
    for ch in s:
        glyph = font.get(ord(ch)) or font[32]
        for gy in range(16):
            bits = glyph[gy]
            for gx in range(8):
                if bits & (0x80 >> gx):
                    xx, yy = x + gx, y + gy
                    if 0 <= xx < W and 0 <= yy < H:
                        img[yy][xx] = rgb
        x += 8


# rgb: bit2 = red, bit1 = green, bit0 = blue
lines = [
    ("MIZAR Z7", 7),      # white
    ("HUB75 LINUX", 3),   # cyan
    ("BOOTING...", 6),    # yellow
    ("3D DISPLAY", 5),    # magenta
]
for i, (s, rgb) in enumerate(lines):
    put_text((W - 8 * len(s)) // 2, i * 16, s, rgb)

# 1-pixel border in dim white, skipping the seam row (PL blanks row_addr 0)
for x in range(W):
    img[1][x] = 7
    img[H - 1][x] = 7
for y in range(1, H):
    img[y][0] = 7
    img[y][W - 1] = 7

frame = bytearray(64 * 3072)
for s in range(64):
    base = s * 3072
    for r in range(32):
        for c in range(128):
            x = 127 - c          # same column mirror as hub75d
            up = img[r][x] & 7
            lo = img[r + 32][x] & 7
            w = up | (lo << 3)
            bit = (r * 128 + c) * 6
            byte, sh = bit >> 3, bit & 7
            v = (w << sh) & 0xFFFF
            frame[base + byte] |= v & 0xFF
            if sh > 2:
                frame[base + byte + 1] |= (v >> 8) & 0xFF

open(OUT, "wb").write(frame)
print("wrote", OUT, len(frame), "bytes")

# quick ASCII preview of the logical image (every 2nd row/col)
for y in range(0, H, 2):
    print("".join("#" if img[y][x] else "." for x in range(0, W, 2)))
