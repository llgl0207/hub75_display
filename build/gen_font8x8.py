#!/usr/bin/env python3
"""Generate sw/linux/hub75_font8x8.h from a Linux font_8x8.c table.

Usage:
    python build/gen_font8x8.py <font_8x8.c> [out.h]

The source table is the classic 8x8 VGA/CP437 console font (public-domain
IBM PC BIOS glyph shapes) mechanically converted by cpi2fnt.  Only the ASCII
32..126 glyphs are taken.  Each glyph is 8 rows, bit7 = leftmost pixel.
"""
import re
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "build/work/vendor_src/font_8x8.c"
DST = sys.argv[2] if len(sys.argv) > 2 else "sw/linux/hub75_font8x8.h"

vals = []
for line in open(SRC, "r", encoding="latin1"):
    m = re.match(r"\s*0x([0-9a-fA-F]{2}),\s*/\*", line)
    if m:
        vals.append(int(m.group(1), 16))
if len(vals) < 256 * 8:
    raise SystemExit("expected 2048 bytes, found %d" % len(vals))

lines = []
lines.append("#ifndef HUB75_FONT8X8_H")
lines.append("#define HUB75_FONT8X8_H")
lines.append("#include <stdint.h>")
lines.append("/* 8x8 glyphs for ASCII 32..126, row-major, bit7 = leftmost pixel.")
lines.append(" * Classic VGA/CP437 console font shapes (public-domain IBM PC BIOS")
lines.append(" * glyphs); table mechanically converted from a Linux font_8x8.c. */")
lines.append("static const uint8_t hub75_font8x8[95][8] = {")
for c in range(32, 127):
    base = c * 8
    row = vals[base:base + 8]
    hexes = ", ".join("0x%02X" % b for b in row)
    lines.append("    {%s}, /* %d */" % (hexes, c))
lines.append("};")
lines.append("#endif")
open(DST, "w", encoding="ascii", newline="\n").write("\n".join(lines) + "\n")
print("wrote", DST, "95x8 glyphs")
