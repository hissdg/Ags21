#!/usr/bin/env bash
# ============================================================================
#  AGS21：把官方 feed 里没有的包取进源码树
# ============================================================================
#
#  为什么需要这一步：
#    openwrt/packages 与 openwrt/luci 这两个官方 feed 里**没有**：
#      * ddns-go             —— 官方只有功能定位完全不同的 ddns-scripts
#      * luci-app-homeproxy  —— ImmortalWrt 独有的代理平台
#      * luci-app-ddns-go    —— 同上，ddns-go 的 LuCI 界面
#    （sing-box 本体官方 feed **有**，net/sing-box，所以 homeproxy 只需要
#      把 LuCI 界面那一层搬过来，不必连 sing-box 一起搬。）
#
#  取法：
#    * 按固定 commit 从 ImmortalWrt 浅取（GitHub 支持 git fetch --depth 1 <SHA>），
#      只复制需要的子目录 —— 不引入 ImmortalWrt 的整个 feed，
#      否则会和官方 luci / packages 里的同名包打架。
#    * 取回来的目录直接放进 $WORKDIR/package/ 下（就是普通的本地包），
#      只做**最小必要**的改动，见下面的 patch 段。
#    * 缓存放在 $WORKDIR/.vendor/，同一个 commit 不会重复下载。
#
#  升级第三方包 = 改下面 IV_*_COMMIT 两个变量（改完两个版本号也要跟着改）。
#
#  用法：  bash vendor.sh [WORKDIR]
# ============================================================================
set -euo pipefail

WORKDIR="${1:-${AGS21_WORKDIR:-$HOME/openwrt-ags21}}"

# --- 钉死的来源 ------------------------------------------------------------
IV_LUCI_URL="https://github.com/immortalwrt/luci.git"
IV_LUCI_COMMIT="5fc1fac5684cac6eee2c7fbff78c65b867980dd8"	# master @ 2026.10.02
IV_LUCI_VERSION="2026.10.02"

IV_PKGS_URL="https://github.com/immortalwrt/packages.git"
IV_PKGS_COMMIT="25ad600a90980bed1ee76a212f9a5e42b499bb62"	# master @ 2026.10.10

CACHE="$WORKDIR/.vendor"
DEST="$WORKDIR/package"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

[ -d "$WORKDIR/target/linux/mediatek" ] \
	|| die "WORKDIR 看起来不是 OpenWrt 源码树：$WORKDIR"

# ---------------------------------------------------------------- 浅取一个 commit
fetch_repo() {
	# 注意：不能写成 `local name="$1" dir="$CACHE/$name"` —— bash 会先把整行的
	# 所有词展开再赋值，$name 那一刻还没定义，在 set -u 下直接报
	# "name: unbound variable"。所以分成两行。
	local name="$1" url="$2" commit="$3"
	local dir="$CACHE/$name"

	if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$commit" ]; then
		log "vendor/$name 已在 $(echo "$commit" | cut -c1-12)，跳过下载"
		return 0
	fi

	log "取 vendor/$name @ $(echo "$commit" | cut -c1-12)"
	rm -rf "$dir"
	mkdir -p "$dir"
	git -C "$dir" init -q
	git -C "$dir" remote add origin "$url"
	# 只取这一个 commit（不拉整仓历史）。上游删了 commit 或网络不通都会在这里失败。
	git -C "$dir" fetch -q --depth 1 origin "$commit" \
		|| die "取 $name 失败：网络问题，或上游已经没有这个 commit（$commit）"
	git -C "$dir" checkout -q FETCH_HEAD
	[ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] \
		|| die "$name 取回来的 SHA 与预期不符"
}

log "准备第三方包缓存：$CACHE"
mkdir -p "$CACHE" "$DEST"
fetch_repo luci     "$IV_LUCI_URL" "$IV_LUCI_COMMIT"
fetch_repo packages "$IV_PKGS_URL" "$IV_PKGS_COMMIT"

# ---------------------------------------------------------------- 复制子目录
copy_pkg() {
	local src="$1" name="$2"

	[ -d "$src" ] || die "上游里找不到 $name（$src）"
	rm -rf "$DEST/$name"
	mkdir -p "$DEST/$name"
	cp -a "$src/." "$DEST/$name/"
	rm -rf "$DEST/$name/.git"	# 上游可能带 .git* 残留

	printf '  %-22s %s 个文件  %s\n' "$name" \
		"$(find "$DEST/$name" -type f | wc -l)" \
		"$(du -sh "$DEST/$name" | cut -f1)"
}

log "复制需要的包到 $DEST"
copy_pkg "$CACHE/packages/net/ddns-go"                 ddns-go
copy_pkg "$CACHE/luci/applications/luci-app-ddns-go"   luci-app-ddns-go
copy_pkg "$CACHE/luci/applications/luci-app-homeproxy" luci-app-homeproxy

# ---------------------------------------------------------------- 最小补丁
# 上游的包是「住在 feed 里」的，两个假设在我们这里不成立：
#
#  ① include 用相对路径：
#       packages/net/ddns-go/Makefile        include ../../lang/golang/golang-package.mk
#       applications/luci-app-*/Makefile     include ../../luci.mk
#     这两个 ../.. 是从 feeds/<feed>/<子目录>/ 往上数两级的写法。
#     包一旦搬到 $WORKDIR/package/ 下，就必须改成绝对指向 feed 里的那个 mk。
#
#  ② 版本号：
#     luci.mk 里 VERSION:=$(if $(PKG_VERSION),...,$(PKG_SRC_VERSION))，
#     而 PKG_SRC_VERSION 是用 `git log -1` 在**包目录所在的 git 仓库**里算出来的。
#     vendor 进来的目录在 OpenWrt 主仓里是 untracked（不在 luci feed 的 git 里），
#     findrev 会返回 "0"，版本就退化成 0。所以这里把版本显式钉在我们 pin 的日期上。
#
# 改完还会断言一遍（改不到就报错退出，不会悄悄放过去）。
log "打最小补丁"
python3 - "$DEST" "$IV_LUCI_VERSION" <<'PYEOF'
import pathlib
import re
import sys

dest = pathlib.Path(sys.argv[1])
luci_ver = sys.argv[2]

GOLANG_OLD = 'include ../../lang/golang/golang-package.mk'
GOLANG_NEW = 'include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk'
LUCI_OLD = 'include ../../luci.mk'
LUCI_NEW = 'include $(TOPDIR)/feeds/luci/luci.mk'

changed = []


def patch(pkg, kind):
    path = dest / pkg / 'Makefile'

    if not path.is_file():
        raise SystemExit('  [失败] 缺 %s' % path)

    src = path.read_text(encoding='utf-8')
    orig = src

    if kind == 'luci':
        src = src.replace(LUCI_OLD, LUCI_NEW)

        if LUCI_NEW not in src:
            raise SystemExit(
                '  [失败] %s/Makefile 里找不到 luci.mk 的 include，'
                '上游结构可能变了，请人工确认' % pkg)

        if 'PKG_VERSION:=' not in src:
            src, n = re.subn(r'(?m)^(include \$\(TOPDIR\)/rules\.mk[ \t]*)$',
                             r'\1\n\nPKG_VERSION:=' + luci_ver, src, count=1)
            if n != 1:
                raise SystemExit('  [失败] %s/Makefile 里找不到 rules.mk 锚点' % pkg)

        if 'PKG_PO_VERSION:=' not in src:
            src, n = re.subn(r'(?m)^(PKG_VERSION:=.*)$',
                             r'\1\nPKG_PO_VERSION:=' + luci_ver, src, count=1)
            if n != 1:
                raise SystemExit('  [失败] %s/Makefile 里找不到 PKG_VERSION 锚点' % pkg)
    else:
        src = src.replace(GOLANG_OLD, GOLANG_NEW)

        if GOLANG_NEW not in src:
            raise SystemExit(
                '  [失败] %s/Makefile 里找不到 golang-package.mk 的 include，'
                '上游结构可能变了，请人工确认' % pkg)

    # 收尾断言：不许再有从包目录往外数级的相对 include
    for line in src.splitlines():
        if line.strip().startswith('include ') and '../../' in line:
            raise SystemExit('  [失败] %s/Makefile 里还有未修正的相对 include：%s'
                             % (pkg, line.strip()))

    if src != orig:
        path.write_text(src, encoding='utf-8')
        changed.append(pkg)

    print('  %-22s %-18s %s' % (pkg, kind, '已打补丁' if src != orig else '无需改动'))


patch('ddns-go', 'golang')
patch('luci-app-ddns-go', 'luci')
patch('luci-app-homeproxy', 'luci')

print()
print('  说明：luci.mk 里的 "%s" 来自 luci feed（官方），"golang" 来自 packages feed。' % LUCI_NEW)
PYEOF

# ---------------------------------------------------------------- 复查
log "复查（补丁后的关键行）"
for p in ddns-go luci-app-ddns-go luci-app-homeproxy; do
	printf '  ---- %s ----\n' "$p"
	grep -nE '^include |^PKG_VERSION|^PKG_PO_VERSION|^PKG_RELEASE|^LUCI_(TITLE|DEPENDS)' \
		"$DEST/$p/Makefile" | sed 's/^/    /'
done

log "完成：第三方包已就位（$DEST）"
