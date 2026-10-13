#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 FIT 镜像（.itb）里抠出子镜像，便于独立验证 dtb 内容。

为什么需要它：主机侧只编了 mkimage，没有 dumpimage（25.12 的 host 工具集里没有）。
而"新固件里的 dtb 到底声明了几个网口"这种事必须**从最终产物里**验，不能只看源 dts
编出来的临时 dtb —— 中间可能被别的东西覆盖。

顺带也把 FIT 的 configurations / 子镜像清单打出来，等价于 `mkimage -l`。

用法:
    python fit_extract.py <itb>                          # 只列清单
    python fit_extract.py <itb> --type flat_dt -o x.dtb  # 按类型抠
    python fit_extract.py <itb> --name fdt-1  -o x.dtb   # 按名字抠
"""
import struct
import sys

FDT_BEGIN_NODE = 0x1
FDT_END_NODE = 0x2
FDT_PROP = 0x3
FDT_NOP = 0x4
FDT_END = 0x9

TYPE_NAMES = {
    "kernel": "kernel", "flat_dt": "flat_dt", "ramdisk": "ramdisk",
    "filesystem": "filesystem", "firmware": "firmware",
}


def _u32(b, off):
    return struct.unpack_from(">I", b, off)[0]


def parse_fdt(blob):
    """返回 {路径: {属性名: 原始字节}}，路径形如 /images/fdt-1。"""
    if _u32(blob, 0) != 0xD00DFEED:
        raise ValueError("不是 FDT/FIT 格式（magic=%08x）" % _u32(blob, 0))
    off_struct = _u32(blob, 8)
    off_strings = _u32(blob, 12)

    def cstr(off):
        end = blob.index(b"\0", off)
        return blob[off:end].decode("utf-8", "replace")

    nodes = {}
    stack = []
    pos = off_struct
    while True:
        tok = _u32(blob, pos)
        pos += 4
        if tok == FDT_BEGIN_NODE:
            name = cstr(pos)
            pos = (pos + len(name) + 1 + 3) & ~3
            stack.append(name)
            nodes["/" + "/".join(n for n in stack if n)] = {}
        elif tok == FDT_END_NODE:
            stack.pop()
        elif tok == FDT_PROP:
            plen = _u32(blob, pos)
            poff = _u32(blob, pos + 4)
            pos += 8
            pname = cstr(off_strings + poff)
            data = blob[pos:pos + plen]
            pos = (pos + plen + 3) & ~3
            nodes["/" + "/".join(n for n in stack if n)][pname] = data
        elif tok == FDT_NOP:
            pass
        elif tok == FDT_END:
            break
        else:
            raise ValueError("结构块里出现未知 token %d（偏移 0x%x）" % (tok, pos - 4))
    return nodes


def s(data):
    return data.split(b"\0")[0].decode("utf-8", "replace") if data else ""


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 1
    itb = args[0]
    want_type = want_name = out = None
    i = 1
    while i < len(args):
        if args[i] == "--type":
            want_type = args[i + 1]; i += 2
        elif args[i] == "--name":
            want_name = args[i + 1]; i += 2
        elif args[i] == "-o":
            out = args[i + 1]; i += 2
        else:
            print("未知参数: %s" % args[i])
            return 1

    blob = open(itb, "rb").read()
    nodes = parse_fdt(blob)
    print("文件: %s  (%d 字节)" % (itb, len(blob)))
    print("totalsize=%d  结构区=%d  字符串区=%d"
          % (_u32(blob, 4), _u32(blob, 36), _u32(blob, 32)))
    print()

    images = {}
    for path, props in nodes.items():
        if path.startswith("/images/") and path.count("/") == 2:
            name = path.rsplit("/", 1)[1]
            images[name] = {
                "desc": s(props.get("description", b"")),
                "type": s(props.get("type", b"")),
                "os": s(props.get("os", b"")),
                "pos": _u32(props["data-position"], 0) if "data-position" in props else None,
                "size": _u32(props["data-size"], 0) if "data-size" in props else None,
            }
    print("=== 子镜像 ===")
    for name, m in sorted(images.items()):
        print("  %-12s type=%-10s size=%-9s pos=%-9s %s"
              % (name, m["type"], m["size"],
                 ("0x%x" % m["pos"]) if m["pos"] is not None else "-", m["desc"]))

    print()
    print("=== configurations ===")
    for path in sorted(nodes):
        if path.startswith("/configurations/") and path.count("/") == 2:
            cname = path.rsplit("/", 1)[1]
            props = nodes[path]
            refs = ", ".join("%s=%s" % (k, s(v)) for k, v in props.items()
                             if k.startswith("fdt") or k.startswith("kernel") or k.startswith("ramdisk"))
            print("  %-24s %s" % (cname, refs))
    cfg_root = nodes.get("/configurations", {})
    print("  default = %r" % s(cfg_root.get("default", b"")))

    if not (want_type or want_name):
        return 0

    pick = None
    for name, m in images.items():
        if want_name and name == want_name:
            pick = (name, m); break
        if want_type and m["type"] == want_type:
            pick = (name, m); break
    if not pick:
        print("\n[错误] 没找到匹配的子镜像（type=%s name=%s）" % (want_type, want_name))
        return 2
    name, m = pick
    if m["pos"] is None or m["size"] is None:
        print("\n[错误] %s 没有 data-position/data-size（可能是内联数据，未用 -E 外部模式）" % name)
        return 3
    data = blob[m["pos"]:m["pos"] + m["size"]]
    if len(data) != m["size"]:
        print("\n[错误] 数据越界：要 %d 字节，只取到 %d" % (m["size"], len(data)))
        return 4
    if not out:
        out = "%s.bin" % name
    with open(out, "wb") as f:
        f.write(data)
    print("\n已抠出 %s（%d 字节）-> %s" % (name, len(data), out))
    print("  前 4 字节: %s  (d00dfeed = 设备树 / 68737173 = squashfs)"
          % " ".join("%02x" % b for b in data[:4]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
