"""Minimal FIT/DTB parser: list the tree, extract sub-image data."""
import struct
import sys

FDT_MAGIC = 0xD00DFEED
BEGIN_NODE, END_NODE, PROP, NOP, END = 1, 2, 3, 4, 9


class Node:
    def __init__(self, name):
        self.name = name
        self.props = {}
        self.children = []


def parse_fdt(data):
    (magic, totalsize, off_struct, off_strings, off_rsv, version,
     last_comp, boot_cpu, size_strings, size_struct) = struct.unpack(
        ">10I", data[:40])
    if magic != FDT_MAGIC:
        raise ValueError("not an FDT")
    strings = data[off_strings:off_strings + size_strings]
    pos = off_struct
    root = Node("")
    stack = [root]
    while pos < off_struct + size_struct:
        tok = struct.unpack(">I", data[pos:pos + 4])[0]
        pos += 4
        if tok == BEGIN_NODE:
            end = data.index(b"\0", pos)
            name = data[pos:end].decode("latin1")
            pos = (end + 4) & ~3
            n = Node(name)
            stack[-1].children.append(n)
            stack.append(n)
        elif tok == END_NODE:
            stack.pop()
        elif tok == PROP:
            ln, nameoff = struct.unpack(">II", data[pos:pos + 8])
            pos += 8
            val = data[pos:pos + ln]
            pos = (pos + ln + 3) & ~3
            name = strings[nameoff:strings.index(b"\0", nameoff)].decode("latin1")
            stack[-1].props[name] = val
        elif tok == NOP:
            pass
        elif tok == END:
            break
        else:
            raise ValueError("bad token %d at %d" % (tok, pos))
    # The structure block starts with the real root node (name ""), which is
    # a child of our synthetic holder; return the real root.
    if not root.props and len(root.children) == 1 and root.children[0].name == "":
        return root.children[0]
    return root


def _pad4(buf):
    while len(buf) % 4:
        buf.append(0)


def serialize(root):
    """Serialize a parsed tree back to an FDT blob."""
    strings = bytearray()
    stroff = {}

    def name_off(name):
        if name not in stroff:
            stroff[name] = len(strings)
            strings.extend(name.encode("latin1") + b"\0")
        return stroff[name]

    body = bytearray()

    def emit(n):
        body.extend(struct.pack(">I", BEGIN_NODE))
        body.extend(n.name.encode("latin1") + b"\0")
        _pad4(body)
        for k, v in n.props.items():
            body.extend(struct.pack(">III", PROP, len(v), name_off(k)))
            body.extend(v)
            _pad4(body)
        for c in n.children:
            emit(c)
        body.extend(struct.pack(">I", END_NODE))

    emit(root)
    body.extend(struct.pack(">I", END))

    off_rsv = 40
    rsv = b"\0" * 16
    off_struct = off_rsv + len(rsv)
    off_strings = off_struct + len(body)
    total = off_strings + len(strings)
    header = struct.pack(">10I", FDT_MAGIC, total, off_struct, off_strings,
                         off_rsv, 17, 16, 0, len(strings), len(body))
    return bytes(header + rsv + bytes(body) + bytes(strings))


def walk(node, path=""):
    p = path + "/" + node.name if node.name else path
    yield p, node
    for c in node.children:
        yield from walk(c, p)


def prop_str(val):
    raw = val.rstrip(b"\0")
    try:
        s = raw.decode("ascii")
        if all(32 <= ord(c) < 127 or c in "\t\n" for c in s):
            return '"%s"' % s
    except Exception:
        pass
    if len(val) % 4 == 0 and len(val) <= 64:
        return "<" + " ".join("%08x" % x for x in struct.unpack(">%dI" % (len(val)//4), val)) + ">"
    return val[:16].hex() + ("..." if len(val) > 16 else "")


def dump(path, node, maxprops=25):
    print(path or "/")
    for k, v in list(node.props.items())[:maxprops]:
        print("    %-24s %s" % (k, prop_str(v)))


def find(root, name):
    for p, n in walk(root):
        if n.name == name:
            return p, n
    return None, None


def extract_images(fit):
    """Return dict image-node-name -> data property bytes."""
    out = {}
    for p, n in walk(fit):
        if "data" in n.props and n.name not in ("", "images"):
            out[n.name] = n.props["data"]
    return out


if __name__ == "__main__":
    mode = sys.argv[1]
    fn = sys.argv[2]
    data = open(fn, "rb").read()
    root = parse_fdt(data)
    if mode == "dump":
        for p, n in walk(root):
            dump(p, n)
    elif mode == "find":
        pat = sys.argv[3].lower()
        for p, n in walk(root):
            if pat in p.lower():
                dump(p, n)
    elif mode == "extract":
        outdir = sys.argv[3]
        import os
        os.makedirs(outdir, exist_ok=True)
        for name, blob in extract_images(root).items():
            safe = name.replace("@", "_").replace("/", "_")
            with open(os.path.join(outdir, safe + ".bin"), "wb") as f:
                f.write(blob)
            print(safe, len(blob))
