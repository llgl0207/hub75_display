"""Host-side preview of hub75_anim_helix geometry (no board needed).

Rebuilds the voxel grid exactly like the C code at t = 0 and projects it
along world -y, which is what a side observer of the swept volume sees.
Writes build/reports/helix_preview.png.
"""
import math
import struct
import zlib

GX = GY = 128
GZ = 64
R = 24.0
TUBE = 3.2
PITCH = 0.30
RUNG_STEP = 6
RUNG_R = 1.6
RUNG_SAMPLES = 24

COL_A = (255, 0, 0)
COL_B = (0, 255, 255)
COL_R = (255, 255, 255)


def stamp(grid, gz, wx, wy, rad, col):
    cx = math.floor(wx + 64.0)
    cy = math.floor(wy + 64.0)
    ir = math.ceil(rad)
    r2 = rad * rad
    for dy in range(-ir, ir + 1):
        iy = cy + dy
        if iy < 0 or iy >= GY:
            continue
        py = iy - 63.5
        ey = py - wy
        for dx in range(-ir, ir + 1):
            ix = cx + dx
            if ix < 0 or ix >= GX:
                continue
            px = ix - 63.5
            ex = px - wx
            if ex * ex + ey * ey <= r2:
                grid[(ix, iy, gz)] = col


def build(phase=0.0, zoff=0.0):
    grid = {}
    for gz in range(GZ):
        zw = 31.5 - gz
        a = PITCH * (zw - zoff) + phase
        x1 = R * math.cos(a)
        y1 = R * math.sin(a)
        stamp(grid, gz, x1, y1, TUBE, COL_A)
        stamp(grid, gz, -x1, -y1, TUBE, COL_B)
        if gz % RUNG_STEP == 3:
            for i in range(RUNG_SAMPLES + 1):
                u = i / RUNG_SAMPLES
                stamp(grid, gz, x1 * (1 - 2 * u), y1 * (1 - 2 * u), RUNG_R, COL_R)
    return grid


def render_front(grid):
    """128x64 view from world -y: nearest voxel along y wins."""
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


def write_png(path, width, height, rgb):
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw.extend(rgb[y * width * 3:(y + 1) * width * 3])

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


if __name__ == "__main__":
    g = build()
    print("lit voxels:", len(g))
    img = render_front(g)
    out = "build/reports/helix_preview.png"
    write_png(out, 128, 64, img)
    print("wrote", out)
