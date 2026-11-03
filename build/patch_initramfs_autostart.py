#!/usr/bin/env python3
"""Patch image.ub: add a hub75-console launcher to the initramfs and make the
serial console start hub75d at boot (falling back to the getty if it dies).

The vendor root filesystem is an initramfs inside the FIT (image.ub); the ext4
partition is only a data disk, so /etc changes do not survive a reboot. This
tool repacks the newc cpio archive (preserving every header field), then
replaces the FIT's ramdisk@1 data and sha1 hash.

Usage: python build/patch_initramfs_autostart.py <in.ub> <out.ub>
"""
import gzip
import hashlib
import importlib.util
import re
import sys

spec = importlib.util.spec_from_file_location(
    "pib", "build/patch_image_ub.py")
pib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pib)

LAUNCHER = b"""#!/bin/sh
mkdir -p /run/media/mmcblk0p1
mount -t vfat /dev/mmcblk0p1 /run/media/mmcblk0p1 2>/dev/null
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin
ln -sf /run/media/mmcblk0p1/3dplay /bin/3dplay
ln -sf /run/media/mmcblk0p1/3dplay /usr/bin/3dplay
if [ -x /run/media/mmcblk0p1/hub75d ]; then
  printf 'shell=/bin/sh\\n' > /etc/hub75.conf
  /run/media/mmcblk0p1/hub75d
fi
exec /bin/start_getty 115200 ttyPS0 vt102
"""

LAUNCHER_PATH = "usr/bin/hub75-console"
INITTAB_PATH = "etc/inittab"


def parse_newc(data):
    entries = []
    pos = 0
    while True:
        magic = data[pos:pos + 6]
        if magic not in (b"070701", b"070702"):
            raise SystemExit("bad cpio magic at %d" % pos)
        hdr = bytearray(data[pos:pos + 110])
        namesize = int(hdr[94:102], 16)
        filesize = int(hdr[54:62], 16)
        name = data[pos + 110:pos + 110 + namesize - 1].decode("utf-8", "replace")
        off = (pos + 110 + namesize + 3) & ~3
        filedata = data[off:off + filesize]
        entries.append([hdr, name, filedata])
        pos = (off + filesize + 3) & ~3
        if name == "TRAILER!!!":
            break
    return entries


def emit_newc(entries):
    out = bytearray()
    for hdr, name, filedata in entries:
        hdr[54:62] = ("%08X" % len(filedata)).encode()
        nb = name.encode() + b"\0"
        hdr[94:102] = ("%08X" % len(nb)).encode()
        out += hdr
        out += nb
        while len(out) % 4:
            out += b"\0"
        out += filedata
        while len(out) % 4:
            out += b"\0"
    return bytes(out)


def new_entry(name, filedata, mode=0o100755, ino=22222):
    hdr = bytearray(b"070701" + b"0" * 104)
    fields = [ino, mode, 0, 0, 1, 0, len(filedata), 0, 0, 0, 0,
              len(name) + 1, 0]
    pos = 6
    for f in fields:
        hdr[pos:pos + 8] = ("%08X" % f).encode()
        pos += 8
    return [hdr, name, filedata]


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    buf = open(src, "rb").read()
    fit, rsv = pib.parse_fdt(buf, 0)
    images = pib.find_node(fit, lambda n: n.name == "images")
    rd = pib.find_node(images, lambda n: n.name == "ramdisk@1")
    if not rd:
        raise SystemExit("FIT has no ramdisk@1")
    old_gz = rd.prop("data")

    entries = parse_newc(gzip.decompress(old_gz))

    # Replace the PS0 line with the launcher.
    found_launcher = False
    for e in entries:
        if e[1].endswith("hub75-console"):
            found_launcher = True
        if e[1] == INITTAB_PATH:
            text = e[2].decode("utf-8", "replace")
            new_line = "PS0:12345:respawn:/usr/bin/hub75-console"
            text2, n = re.subn(r"(?m)^PS0:.*$", new_line, text)
            if n != 1:
                raise SystemExit("PS0 line not found in inittab")
            e[2] = text2.encode()
            print("inittab PS0 ->", new_line)

    if not found_launcher:
        trailer = entries[-1]
        entries.insert(-1, new_entry(LAUNCHER_PATH, LAUNCHER))
        print("added", LAUNCHER_PATH)

    new_cpio = emit_newc(entries)
    new_gz = gzip.compress(new_cpio, compresslevel=9, mtime=0)
    print("cpio %d -> %d, gz %d -> %d" % (
        len(old_gz), len(new_gz), len(old_gz), len(new_gz)))

    rd.set_prop("data", new_gz)
    h = pib.find_node(rd, lambda n: n.name.startswith("hash@"))
    if not h or h.prop("value") is None:
        raise SystemExit("ramdisk has no hash node")
    h.set_prop("value", hashlib.sha1(new_gz).digest())
    new_fit = pib.serialize_fdt(fit, rsv)
    open(dst, "wb").write(new_fit)
    print("image.ub %d -> %d" % (len(buf), len(new_fit)))

    # Verify by re-parsing and decompressing.
    chk, _ = pib.parse_fdt(new_fit, 0)
    imgs = pib.find_node(chk, lambda n: n.name == "images")
    rd2 = pib.find_node(imgs, lambda n: n.name == "ramdisk@1")
    gz2 = rd2.prop("data")
    cpio2 = gzip.decompress(gz2)
    names = [e[1] for e in parse_newc(cpio2)]
    h2 = pib.find_node(rd2, lambda n: n.name.startswith("hash@"))
    print("verify:", LAUNCHER_PATH in names,
          "hash_ok", hashlib.sha1(gz2).digest() == h2.prop("value"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
