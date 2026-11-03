"""Enable the SD1 (WiFi) controller in the running DTB and repack image.ub.

The current 4.14 DTB has /amba/mmc@e0101000 status="disabled"; the vendor
3.17 WiFi demo DTB has the same controller status="okay".  Flip it and put
the patched DTB back into the FIT, updating its sha1 so U-Boot accepts it.
"""
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import fdt_tool as F  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DTB_IN = os.path.join(ROOT, "build", "work", "image_ub_parts",
                      "fdt_system-top.dtb.bin")
FIT_IN = os.path.join(ROOT, "build", "work", "vendor_linux", "image.ub")
DTB_OUT = os.path.join(ROOT, "build", "work", "image_ub_parts",
                       "fdt_system-top-sd1.dtb")
FIT_OUT = os.path.join(ROOT, "build", "work", "vendor_linux",
                       "image_sd1.ub")


def find_path(root, path):
    node = root
    for part in [p for p in path.split("/") if p]:
        nxt = None
        for c in node.children:
            if c.name == part:
                nxt = c
                break
        if nxt is None:
            return None
        node = nxt
    return node


def main():
    dtb = open(DTB_IN, "rb").read()
    dt = F.parse_fdt(dtb)
    mmc = find_path(dt, "/amba/mmc@e0101000")
    if mmc is None:
        print("mmc node not found")
        return 1
    old = mmc.props.get("status", b"")
    mmc.props["status"] = b"okay\0"
    new_dtb = F.serialize(dt)
    open(DTB_OUT, "wb").write(new_dtb)
    print("dtb %d -> %d bytes, status %r -> okay" %
          (len(dtb), len(new_dtb), old))

    fit = open(FIT_IN, "rb").read()
    ft = F.parse_fdt(fit)
    fdt_node = find_path(ft, "/images/fdt@system-top.dtb")
    if fdt_node is None:
        print("fit fdt node not found")
        return 1
    fdt_node.props["data"] = new_dtb
    h = find_path(ft, "/images/fdt@system-top.dtb/hash@1")
    if h is not None:
        h.props["value"] = hashlib.sha1(new_dtb).digest()
        print("updated fdt hash", h.props.get("algo"))
    new_fit = F.serialize(ft)
    open(FIT_OUT, "wb").write(new_fit)
    print("fit %d -> %d bytes -> %s" % (len(fit), len(new_fit), FIT_OUT))

    # verify round-trip
    v = F.parse_fdt(new_fit)
    fn = find_path(v, "/images/fdt@system-top.dtb")
    nd = fn.props["data"]
    vd = F.parse_fdt(nd)
    st = find_path(vd, "/amba/mmc@e0101000").props["status"]
    print("verify fdt data %d bytes, status %r" % (len(nd), st))
    return 0


if __name__ == "__main__":
    sys.exit(main())
