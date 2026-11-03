#!/usr/bin/env python3
"""Enable USB0 (host, ULPI PHY) in the vendor image.ub device tree.

The vendor PetaLinux DTB ships usb@e0002000 with status = "disabled".  Their
own device-tree overlay (10_petalinux_hdmi_wifi_...system-user.dtsi) enables
it as a host port with the Xilinx ulpi-phy at 0xe0002000, view-port 0x170 and
drv-vbus.  This tool reproduces that overlay inside the FIT:

  * usb@e0002000: status = "okay", dr_mode = "host", usb-phy = <&usb_phy0>
  * add /usb_phy@0 (compatible "ulpi-phy", reg 0xe0002000, view-port 0x170)
  * update the FIT fdt@1 hash

Usage:
    python build/patch_dtb_usb.py <in.ub> <out.ub>
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


def max_phandle(root):
    hi = 0
    for n in walk(root):
        for name in ("phandle", "linux,phandle"):
            v = n.prop(name)
            if v and len(v) == 4:
                hi = max(hi, struct.unpack(">I", v)[0])
    return hi


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

    usb = find_node(
        dtb, lambda n: (n.prop("compatible") or b"").startswith(b"xlnx,zynq-usb-2.20a"))
    if not usb:
        raise SystemExit("DTB has no xlnx,zynq-usb node")

    ph = max_phandle(dtb) + 1
    phy = Node("usb_phy@0")
    phy.set_prop("compatible", b"ulpi-phy\0")
    phy.set_prop("#phy-cells", struct.pack(">I", 0))
    phy.set_prop("reg", struct.pack(">II", 0xe0002000, 0x1000))
    phy.set_prop("view-port", struct.pack(">I", 0x170))
    phy.set_prop("drv-vbus", b"")
    phy.set_prop("phandle", struct.pack(">I", ph))
    phy.set_prop("linux,phandle", struct.pack(">I", ph))
    dtb.children.append(phy)

    # MIO46 is the USB0 PHY reset (active low).  The FSBL configures the pin
    # as GPIO but never drives it, and the kernel gates the GPIO APER clock at
    # late init, so userspace cannot release the reset either.  A gpio-hog
    # drives it high at gpiochip registration (before the USB driver probes),
    # which lets the ULPI PHY answer the viewport access.
    gpio = find_node(
        dtb, lambda n: (n.prop("compatible") or b"").startswith(b"xlnx,zynq-gpio"))
    if not gpio:
        raise SystemExit("DTB has no xlnx,zynq-gpio node")
    hog = Node("usb0-phy-reset")
    hog.set_prop("gpio-hog", b"")
    hog.set_prop("gpios", struct.pack(">II", 46, 0))
    hog.set_prop("output-high", b"")
    hog.set_prop("line-name", b"usb0-phy-reset\0")
    gpio.children.append(hog)

    usb.set_prop("status", b"okay\0")
    usb.set_prop("dr_mode", b"host\0")
    usb.set_prop("usb-phy", struct.pack(">I", ph))

    new_dtb = serialize_fdt(dtb, dtb_rsv)

    fdt_node.set_prop("data", new_dtb)
    hash_node = find_node(fdt_node, lambda n: n.name.startswith("hash@"))
    if not hash_node or hash_node.prop("value") is None:
        raise SystemExit("fdt image has no hash value")
    hash_node.set_prop("value", hashlib.sha1(new_dtb).digest())

    new_fit = serialize_fdt(fit, rsv)
    open(dst, "wb").write(new_fit)

    chk, _ = parse_fdt(new_fit, 0)
    imgs = find_node(chk, lambda n: n.name == "images")
    fn = find_node(imgs, lambda n: n.name.startswith("fdt@"))
    d = fn.prop("data")
    dt, _ = parse_fdt(d, 0)
    u = find_node(dt, lambda n: (n.prop("compatible") or b"").startswith(b"xlnx,zynq-usb-2.20a"))
    p = find_node(dt, lambda n: (n.prop("compatible") or b"").startswith(b"ulpi-phy"))
    hn = find_node(fn, lambda n: n.name.startswith("hash@"))
    print("old image.ub", len(buf), "-> new", len(new_fit))
    print("old dtb", len(old_dtb), "-> new", len(new_dtb))
    print("usb status:", u.prop("status"), "dr_mode:", u.prop("dr_mode"),
          "usb-phy:", struct.unpack(">I", u.prop("usb-phy"))[0])
    print("usb_phy node:", bool(p), "phandle:", struct.unpack(">I", p.prop("phandle"))[0])
    g = find_node(dt, lambda n: (n.prop("compatible") or b"").startswith(b"xlnx,zynq-gpio"))
    h = find_node(g, lambda n: n.prop("gpio-hog") is not None)
    print("gpio-hog:", h.name if h else None,
          "gpios:", list(struct.unpack(">II", h.prop("gpios"))) if h else None,
          "output-high:", h is not None and h.prop("output-high") is not None)
    print("hash match:", hashlib.sha1(d).digest() == hn.prop("value"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
