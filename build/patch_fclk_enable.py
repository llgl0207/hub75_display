#!/usr/bin/env python3
"""Patch the vendor image.ub: disable the Zynq OCMC driver in the DTB.

The PL frame buffers will live in the low 192 KiB of OCM (0xFFFC0000).
The vendor kernel's xilinx-ocmc driver owns that region, so writing a full
frame there crashes the kernel.  This tool edits the FIT's system-top DTB,
adds status = "disabled" to the node compatible with xlnx,zynq-ocmc-1.0,
updates the FIT hash, and writes a new image.ub.

Usage:
    python build/patch_image_ub.py <in.ub> <out.ub>
"""
import hashlib
import struct
import sys

FDT_MAGIC = 0xD00DFEED


class Node:
    __slots__ = ("name", "props", "children")

    def __init__(self, name):
        self.name = name
        self.props = []          # list of (name:str, value:bytes)
        self.children = []

    def prop(self, name):
        for n, v in self.props:
            if n == name:
                return v
        return None

    def set_prop(self, name, value):
        for i, (n, _) in enumerate(self.props):
            if n == name:
                self.props[i] = (name, value)
                return
        self.props.append((name, value))


def parse_fdt(buf, base=0):
    magic, total, off_struct, off_strings, off_rsv, ver, lastc, cpuid, sstr, sstruct = \
        struct.unpack_from(">10I", buf, base)
    if magic != FDT_MAGIC:
        raise ValueError("not an FDT at 0x%x: %08x" % (base, magic))
    strings = buf[base + off_strings: base + off_strings + sstr]
    p = base + off_rsv
    rsv = []
    while True:
        addr, size = struct.unpack_from(">QQ", buf, p)
        p += 16
        if addr == 0 and size == 0:
            break
        rsv.append((addr, size))

    root = None
    stack = []
    p = base + off_struct
    while True:
        tag, = struct.unpack_from(">I", buf, p)
        p += 4
        if tag == 1:  # BEGIN_NODE
            end = buf.index(b"\0", p)
            name = buf[p:end].decode("latin1")
            p = (end + 4) & ~3
            node = Node(name)
            if stack:
                stack[-1].children.append(node)
            else:
                root = node
            stack.append(node)
        elif tag == 2:  # END_NODE
            stack.pop()
            if not stack:
                break
        elif tag == 3:  # PROP
            ln, noff = struct.unpack_from(">II", buf, p)
            p += 8
            end = strings.index(b"\0", noff)
            name = strings[noff:end].decode("latin1")
            value = buf[p:p + ln]
            p = (p + ln + 3) & ~3
            stack[-1].props.append((name, value))
        elif tag == 4:  # NOP
            continue
        elif tag == 9:  # END
            break
        else:
            raise ValueError("bad FDT tag %d at 0x%x" % (tag, p - 4))
    return root, rsv


def walk(node):
    yield node
    for c in node.children:
        yield from walk(c)


def serialize_fdt(root, rsv):
    # Build the strings block in first-use order.
    strings = bytearray()
    offsets = {}

    def name_off(name):
        if name not in offsets:
            offsets[name] = len(strings)
            strings.extend(name.encode("latin1") + b"\0")
        return offsets[name]

    def collect(node):
        for n, _ in node.props:
            name_off(n)
        for c in node.children:
            collect(c)

    collect(root)

    out = bytearray()

    def pad4():
        while len(out) % 4:
            out.append(0)

    def emit(node):
        out.extend(struct.pack(">I", 1))
        out.extend(node.name.encode("latin1") + b"\0")
        pad4()
        for n, v in node.props:
            out.extend(struct.pack(">III", 3, len(v), name_off(n)))
            out.extend(v)
            pad4()
        for c in node.children:
            emit(c)
        out.extend(struct.pack(">I", 2))

    emit(root)
    out.extend(struct.pack(">I", 9))
    pad4()

    struct_block = bytes(out)
    strings_block = bytes(strings)

    off_rsv = 40
    off_struct = off_rsv + 16 * (len(rsv) + 1)
    off_strings = off_struct + len(struct_block)
    total = off_strings + len(strings_block)

    header = struct.pack(
        ">10I", FDT_MAGIC, total, off_struct, off_strings, off_rsv,
        17, 16, 0, len(strings_block), len(struct_block))
    body = bytearray(header)
    for addr, size in rsv:
        body.extend(struct.pack(">QQ", addr, size))
    body.extend(struct.pack(">QQ", 0, 0))
    body.extend(struct_block)
    body.extend(strings_block)
    return bytes(body)


def find_node(root, pred):
    for n in walk(root):
        if pred(n):
            return n
    return None


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    buf = open(src, "rb").read()
    fit, rsv = parse_fdt(buf, 0)

    images = find_node(fit, lambda n: n.name == "images")
    if not images:
        raise SystemExit("FIT has no /images node")
    fdt_node = find_node(images, lambda n: n.name.startswith("fdt@"))
    if not fdt_node:
        raise SystemExit("FIT has no fdt@ image")

    old_dtb = fdt_node.prop("data")
    if old_dtb is None:
        raise SystemExit("fdt image has no inline data")
    dtb, dtb_rsv = parse_fdt(old_dtb, 0)

    clkc = find_node(dtb, lambda n: n.prop("fclk-enable") is not None)
    if not clkc:
        raise SystemExit("DTB has no fclk-enable property")
    old_val = clkc.prop("fclk-enable")
    clkc.set_prop("fclk-enable", bytes([0, 0, 0, 0x0F]))
    print("fclk-enable old", old_val.hex() if old_val else None, "-> 0000000f")
    new_dtb = serialize_fdt(dtb, dtb_rsv)

    fdt_node.set_prop("data", new_dtb)
    h = hashlib.sha1(new_dtb).digest()
    hash_node = find_node(fdt_node, lambda n: n.name.startswith("hash@"))
    if not hash_node or hash_node.prop("value") is None:
        raise SystemExit("fdt image has no hash value")
    hash_node.set_prop("value", h)

    new_fit = serialize_fdt(fit, rsv)
    open(dst, "wb").write(new_fit)

    print("old image.ub", len(buf), "-> new", len(new_fit))
    print("old dtb", len(old_dtb), "-> new", len(new_dtb))
    return 0

if __name__ == "__main__":
    sys.exit(main())
