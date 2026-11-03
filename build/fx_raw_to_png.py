"""Convert fx0/fx1/fx2.raw (128x64 RGB) into one scaled PNG strip."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from preview_helix import write_png  # noqa: E402

W, H = 128, 64
SCALE = 2
NAME = sys.argv[1] if len(sys.argv) > 1 else "fx"


def scale_frame(raw):
    out = bytearray()
    for y in range(H):
        row = raw[y * W * 3:(y + 1) * W * 3]
        srow = bytearray()
        for x in range(W):
            srow.extend(row[x * 3:x * 3 + 3] * SCALE)
        for _ in range(SCALE):
            out.extend(srow)
    return out


frames = []
for i in range(3):
    with open(os.path.join("build", "reports", "fx%d.raw" % i), "rb") as f:
        frames.append(scale_frame(f.read()))

sep = b"\x00" * (W * SCALE * 3) * 2
strip = bytearray()
for i, f in enumerate(frames):
    if i:
        strip.extend(sep)
    strip.extend(f)
height = len(strip) // (W * SCALE * 3)
out = "build/reports/fx_%s.png" % NAME
write_png(out, W * SCALE, height, strip)
print("wrote", out)
