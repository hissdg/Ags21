#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从编出来的 OpenWrt FIT 镜像（*-sysupgrade.itb）里读出 configurations 节点名，
用来确定 U-Boot 环境变量 bootconf 该设成什么。

FIT 本身就是一个 FDT（flattened device tree），所以纯 struct 就能解，
不需要 dtc / libfdt。

用法：
    python3 fit_configs.py openwrt-...-sysupgrade.itb
"""
import struct
import sys

FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9


def parse(payload):
    magic, totalsize, off_struct, off_strings, _, ver, last_ver, _, size_str, size_struct = \
        struct.unpack('>10I', payload[:40])
    if magic != 0xD00DFEED:
        raise SystemExit('不是 FDT（magic=%#x）' % magic)

    strings = payload[off_strings:off_strings + size_str]
    blob = payload[off_struct:off_struct + size_struct]

    def s_at(off):
        end = strings.find(b'\x00', off)
        return strings[off:end].decode('utf-8', 'replace')

    p = 0
    stack = []          # 名字栈
    tree = []           # (路径, {属性名: 原始值})
    while p < len(blob):
        (tok,) = struct.unpack_from('>I', blob, p)
        p += 4
        if tok == FDT_BEGIN_NODE:
            end = blob.find(b'\x00', p)
            name = blob[p:end].decode('utf-8', 'replace')
            p = (end + 4) & ~3
            stack.append(name)
            tree.append(('/' + '/'.join([n for n in stack if n]), {}))
        elif tok == FDT_END_NODE:
            if stack:
                stack.pop()
        elif tok == FDT_PROP:
            length, nameoff = struct.unpack_from('>II', blob, p)
            p += 8
            val = blob[p:p + length]
            p = (p + length + 3) & ~3
            if tree:
                tree[-1][1][s_at(nameoff)] = val
        elif tok == FDT_NOP:
            pass
        elif tok == FDT_END:
            break
        else:
            raise SystemExit('结构块里出现未知 token %d @%d' % (tok, p - 4))
    return tree


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    with open(path, 'rb') as f:
        payload = f.read()

    tree = parse(payload)
    print('文件：%s  (%d 字节)' % (path, len(payload)))
    print()

    print('=== images ===')
    for p, props in tree:
        if p.startswith('/images/') and p.count('/') == 2:
            t = props.get('type', b'').decode('utf-8', 'replace').rstrip('\x00')
            d = props.get('description', b'').decode('utf-8', 'replace').rstrip('\x00')
            print('  %-28s type=%-10s %s' % (p.rsplit('/', 1)[1], t, d))

    print()
    print('=== configurations ===')
    names = []
    default = b''
    for p, props in tree:
        if p == '/configurations':
            default = props.get('default', b'')
        elif p.startswith('/configurations/') and p.count('/') == 2:
            names.append(p.rsplit('/', 1)[1])
            fdt = props.get('fdt', b'').decode('utf-8', 'replace').rstrip('\x00')
            has_kernel = 'kernel' in props
            loadables = props.get('loadables', b'').decode('utf-8', 'replace').rstrip('\x00')
            tag = 'base (kernel' + ('+rootfs)' if loadables else ')') if has_kernel else 'overlay'
            print('  %-40s %-18s fdt=%s' % (p.rsplit('/', 1)[1], tag, fdt))
    default = default.decode('utf-8', 'replace').rstrip('\x00')
    print()
    print('  default = %r' % default)

    print()
    print('=' * 74)
    print('U-Boot 环境变量 bootconf 该设成什么')
    print('=' * 74)
    print()
    if not names:
        print('  !! 一个配置节点都没找到，镜像可能不对')
    elif len(names) == 1:
        print("    setenv bootconf '%s'" % names[0])
        print()
        print('  这个镜像只有 base 配置、没有 overlay。')
        print('  也可以干脆删掉 bootconf，让 U-Boot 用 FIT 里的 default：')
        print('    setenv bootconf')
    else:
        base = [n for n in names if n.startswith('config-')]
        ovl = [n for n in names if not n.startswith('config-')]
        b = base[0] if base else names[0]
        print('  镜像里有 base + %d 个 overlay 配置。U-Boot 用 # 把要用的串起来，' % len(ovl))
        print('  注意是「base + 需要的那个 overlay」，不是全部（全加会同时套上无关 overlay）。')
        print()
        print('  可选组合：')
        print("    setenv bootconf '%s'%s" % (b, ' ' * 20 + '只 base'))
        for o in ovl:
            print("    setenv bootconf '%s#%s'" % (b, o))
        print()
        print('  对照：官方 RAX3000M 的 U-Boot 默认 env 是')
        print("    bootconf=config-1#mt7981b-cmcc-rax3000m-emmc")
        print('  也就是「base + eMMC overlay」，说明这台机器该选带 emmc 的那条。')
    print()
    print('  设完记得 saveenv，否则下次上电又回落到默认值。')
    print('  环境变量存在 GPT 的 ubootenv 分区（LBA 8192，512 KiB）。')
    print('=' * 74)


if __name__ == '__main__':
    main()
