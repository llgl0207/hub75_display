"""Patch the on-card image.ub in place: enable SD1 and fix the FIT hash.

Only 9 bytes (status "disabled" -> "okay\\0\\0\\0\\0") and 20 bytes (sha1 of
the patched DTB) change, so the board can apply the patch with dd instead of
transferring a new 10 MB image.
"""
import hashlib
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIT = os.path.join(ROOT, "build", "work", "vendor_linux", "image.ub")
OUTDIR = os.path.join(ROOT, "build", "work", "fit_patch")
if len(sys.argv) > 1:
    FIT = sys.argv[1]
if len(sys.argv) > 2:
    OUTDIR = sys.argv[2]
FDT_MAGIC = 0xD00DFEED
BEGIN_NODE, END_NODE, PROP, NOP, END = 1, 2, 3, 4, 9


def parse_with_offsets(data):
    """Return header info and a list of (path, prop, value_off, length)."""
    (magic, totalsize, off_struct, off_strings, off_rsv, version,
     last_comp, boot_cpu, size_strings, size_struct) = struct.unpack(
        ">10I", data[:40])
    if magic != FDT_MAGIC:
        raise ValueError("not an FDT")
    strings = data[off_strings:off_strings + size_strings]
    pos = off_struct
    stack = []
    props = []
    while pos < off_struct + size_struct:
        tok = struct.unpack(">I", data[pos:pos + 4])[0]
        pos += 4
        if tok == BEGIN_NODE:
            end = data.index(b"\0", pos)
            name = data[pos:end].decode("latin1")
            pos = (end + 4) & ~3
            stack.append(name)
        elif tok == END_NODE:
            stack.pop()
        elif tok == PROP:
            ln, nameoff = struct.unpack(">II", data[pos:pos + 8])
            pos += 8
            voff = pos
            name = strings[nameoff:strings.index(b"\0", nameoff)].decode("latin1")
            path = "/" + "/".join([s for s in stack if s])
            if path == "/":
                path = "/"
            props.append((path, name, voff, ln))
            pos = (pos + ln + 3) & ~3
        elif tok == NOP:
            pass
        elif tok == END:
            break
        else:
            raise ValueError("bad token")
    return props


def main():
    fit = open(FIT, "rb").read()
    props = parse_with_offsets(fit)
    dtb_data = None
    hash_off = None
    for path, name, off, ln in props:
        if path == "/images/fdt@system-top.dtb" and name == "data":
            dtb_data = (off, ln)
        if path == "/images/fdt@system-top.dtb/hash@1" and name == "value":
            hash_off = (off, ln)
    if not dtb_data or not hash_off:
        print("FIT nodes not found", dtb_data, hash_off)
        return 1
    d_off, d_len = dtb_data
    h_off, h_len = hash_off
    print("FIT dtb data @%d len %d; hash @%d len %d hlen=%d" %
          (d_off, d_len, h_off, h_len, h_len))

    dtb = fit[d_off:d_off + d_len]
    dprops = parse_with_offsets(dtb)
    status = None
    for path, name, off, ln in dprops:
        if path == "/amba/mmc@e0101000" and name == "status":
            status = (off, ln)
    if not status:
        print("status property not found")
        return 1
    s_off, s_len = status
    old = dtb[s_off:s_off + s_len]
    print("dtb status @%d len %d = %r" % (s_off, s_len, old))
    if old != b"disabled\0" or s_len != 9:
        print("unexpected status")
        return 1

    patched = bytearray(dtb)
    patched[s_off:s_off + 9] = b"okay\0\0\0\0\0"
    new_hash = hashlib.sha1(bytes(patched)).digest()
    print("new sha1", new_hash.hex(), "old", fit[h_off:h_off + h_len].hex())

    os.makedirs(OUTDIR, exist_ok=True)
    open(os.path.join(OUTDIR, "status9.bin"), "wb").write(b"okay\0\0\0\0\0")
    open(os.path.join(OUTDIR, "hash20.bin"), "wb").write(new_hash)
    with open(os.path.join(OUTDIR, "offsets.txt"), "w") as f:
        f.write("STATUS_OFF=%d\n" % (d_off + s_off))
        f.write("HASH_OFF=%d\n" % h_off)
        f.write("STATUS_LEN=9\nHASH_LEN=20\n")
        f.write("DTB_DATA_OFF=%d\nDTB_DATA_LEN=%d\n" % (d_off, d_len))

    # verify a local copy
    copy = bytearray(fit)
    copy[d_off + s_off:d_off + s_off + 9] = b"okay\0\0\0\0\0"
    copy[h_off:h_off + h_len] = new_hash
    open(os.path.join(OUTDIR, "image_sd1_inplace.ub"), "wb").write(copy)
    vprops = parse_with_offsets(bytes(copy))
    vd = [x for x in vprops if x[0] == "/images/fdt@system-top.dtb" and x[1] == "data"][0]
    vdtb = bytes(copy[vd[2]:vd[2] + vd[3]])
    vdp = parse_with_offsets(vdtb)
    vst = [x for x in vdp if x[0] == "/amba/mmc@e0101000" and x[1] == "status"][0]
    st = vdtb[vst[2]:vst[2] + vst[3]]
    vh = [x for x in vprops if x[0] == "/images/fdt@system-top.dtb/hash@1" and x[1] == "value"][0]
    print("verify status", st, "hash_match",
          hashlib.sha1(vdtb).digest() == copy[vh[2]:vh[2] + vh[3]])
    print("patch bytes in", OUTDIR)
    return 0


if __name__ == "__main__":
    sys.exit(main())
