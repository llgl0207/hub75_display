"""Host-side preview of hub75_anim_balls (no board needed).

Rebuilds the voxel grid like the C code and writes a 128x256 PNG with four
frames (t = 0.00, 0.25, 0.50, 0.75 s) stacked vertically.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from preview_helix import stamp, write_png  # noqa: E402

GX = GY = 128
GZ = 64
FLOOR = -30.0

# radius, orbit, omega, orbit_phase, period, bounce_phase, height, rgb
BALLS = [
    (6.0, 24.0,  0.90, 0.00, 1.15, 0.00, 40.0, (255, 0, 0)),
    (5.0, 32.0, -0.65, 2.10, 1.45, 0.35, 30.0, (0, 255, 0)),
    (5.0, 14.0,  1.30, 4.20, 0.95, 0.70, 46.0, (0, 0, 255)),
    (4.5, 20.0, -1.10, 1.00, 1.25, 0.15, 36.0, (255, 255, 0)),
]


def stamp_ball(grid, wx, wy, wz, rh, rv, col):
    gz0 = math.floor(31.5 - (wz + rv))
    gz1 = math.ceil(31.5 - (wz - rv))
    for gz in range(max(0, gz0), min(GZ - 1, gz1) + 1):
        pz = 31.5 - gz
        dz = (pz - wz) / rv
        if dz < -1.0 or dz > 1.0:
            continue
        rr = rh * math.sqrt(1.0 - dz * dz)
        if rr > 0.5:
            stamp(grid, gz, wx, wy, rr, col)


def stamp_ring(grid, wx, wy, rad, col):
    gz = math.floor(31.5 - (FLOOR + 1.0))
    steps = int(6.2831853 * rad / 0.9)
    steps = max(16, min(160, steps))
    for i in range(steps):
        a = 6.2831853 * i / steps
        stamp(grid, gz, wx + rad * math.cos(a), wy + rad * math.sin(a), 1.0, col)


def build(t):
    grid = {}
    for (r, orbit, omega, ophase, period, bphase, height, col) in BALLS:
        ang = ophase + omega * t
        bx = orbit * math.cos(ang)
        by = orbit * math.sin(ang)
        tau = math.fmod(t + bphase, period)
        g = 8.0 * height / (period * period)
        v0 = 4.0 * height / period
        zc = FLOOR + r + v0 * tau - 0.5 * g * tau * tau

        d = zc - (FLOOR + r)
        s = 1.0
        if d < 2.5:
            d = max(d, 0.0)
            s = 0.72 + 0.28 * (d / 2.5)
        rv = r * s
        rh = r * (1.0 + 0.35 * (1.0 - s))
        zdraw = zc - (r - rv)

        stamp_ball(grid, bx, by, zdraw, rh, rv, col)
        if tau < 0.32:
            stamp_ring(grid, bx, by, r + tau * 70.0, col)
    return grid


def render_front(grid):
    img = bytearray(128 * 64 * 3)
    for gz in range(GZ):
        for ix in range(GX):
            best = None
            for iy in range(GY):
                c = grid.get((ix, iy, gz))
                if c is not None and (best is None or iy < best[0]):
                    best = (iy, c)
            if best is not None:
                o = (gz * 128 + ix) * 3
                img[o:o + 3] = bytes(best[1])
    return img


if __name__ == "__main__":
    frames = [render_front(build(t)) for t in (0.00, 0.25, 0.50, 0.75)]
    strip = bytearray()
    for f in frames:
        strip.extend(f)
    out = "build/reports/balls_preview.png"
    write_png(out, 128, 64 * len(frames), strip)
    print("wrote", out)
