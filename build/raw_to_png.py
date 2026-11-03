"""Convert raw 128x64 RGB frames from preview_breakout into one PNG strip."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from preview_helix import write_png  # noqa: E402

W, H = 128, 64
SCALE = 2


def load(name):
    with open(os.path.join("build", "reports", name), "rb") as f:
        return f.read()


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


frames = [scale_frame(load("bo_%s.raw" % n)) for n in ("ready", "play", "over")]
sep = b"\x00" * (W * SCALE * 3) * 2
strip = bytearray()
for i, f in enumerate(frames):
    if i:
        strip.extend(sep)
    strip.extend(f)
height = len(strip) // (W * SCALE * 3)
write_png("build/reports/breakout_preview.png", W * SCALE, height, strip)
print("wrote build/reports/breakout_preview.png", W * SCALE, height)
