#!/usr/bin/env bash
# ============================================================================
#  AGS21 自编 OpenWrt 25.12.5 固件 —— 在 WSL 的 Ubuntu 里跑
#
#  用法（在 WSL 里；必须在 Linux 原生文件系统里编译，不能放 /mnt/c）：
#      B=/mnt/c/Users/Administrator/WorkBuddy/2026-10-12-10-39-32/ags21_openwrt/build
#      bash $B/build-ags21.sh --stage=sync   # 只拉源码 + 打补丁，几十秒
#      bash $B/build-ags21.sh --stage=dtb    # 再编一遍设备树，验证 DTS 能否编过
#      bash $B/build-ags21.sh                # 默认 --stage=all，出完整固件
#
#  stage=sync : 拉源码 + 打补丁（用来确认补丁能干净应用）
#  stage=dtb  : 再跑 target/linux/compile，DTS 语法/标签错误会在这里暴露
#               （第一次会连带编工具链，20-40 分钟；之后就快了）
#  stage=all  : 完整编出 ...-aigo_ags21-squashfs-sysupgrade.itb
#
#  脚本幂等：重复跑不会重复追加内容；补丁锚点对不上会明确报错而不是乱改。
# ============================================================================
set -euo pipefail

VERSION="v25.12.5"
WORKDIR="${AGS21_WORKDIR:-$HOME/openwrt-ags21}"
STAGE="all"

for a in "$@"; do
	case "$a" in
		--stage=*)   STAGE="${a#--stage=}" ;;
		--workdir=*) WORKDIR="${a#--workdir=}" ;;
		-h|--help)   sed -n '2,17p' "$0"; exit 0 ;;
		*) echo "未知参数：$a"; exit 2 ;;
	esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
DTS_SRC="$HERE/../mt7981b-aigo-ags21.dts"
MK_ADD="$HERE/filogic.mk.add"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. 环境体检
log "环境体检"
[ -f "$DTS_SRC" ] || die "找不到 $DTS_SRC"
[ -f "$MK_ADD" ]  || die "找不到 $MK_ADD"

case "$WORKDIR" in
	/mnt/*) die "WORKDIR 在 /mnt 下（$WORKDIR）。OpenWrt 必须编在 Linux 原生文件系统里，
     否则大小写敏感、符号链接、9p 性能都会出问题。换路径，例如 \$HOME/openwrt-ags21。" ;;
esac
[ "$(uname -s)" = "Linux" ] || die "要在 Linux/WSL 里跑，当前是 $(uname -s)"

echo "  内核     : $(uname -r)"
echo "  发行版   : $( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || echo 未知)"
echo "  工作目录 : $WORKDIR"
echo "  CPU 核数 : $(nproc)"
echo "  可用空间 : $(df -h "$HOME" | awk 'NR==2{print $4}')（完整编译约需 20-25 GB）"
echo "  内存     : $(awk '/MemTotal/{printf "%.1f GB\n",$2/1048576}' /proc/meminfo)"

if [ -n "${WSL_DISTRO_NAME:-}" ] && [ ! -e /proc/sys/fs/binfmt_misc/WSLInterop ]; then
	warn "看起来像 WSL1。WSL1 编不了 Linux 内核，请先 wsl --set-version <发行版> 2。"
fi

# ---------------------------------------------------------------- 1. 依赖
log "检查构建依赖"
MISSING=""
for c in gcc g++ make perl python3 git rsync unzip gawk gettext file wget; do
	command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"
done
if [ -n "$MISSING" ]; then
	warn "缺少：$MISSING —— 用 apt 安装"
	sudo apt-get update
	sudo apt-get install -y build-essential clang flex bison g++ gawk \
		gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev \
		python3-distutils python3-setuptools rsync swig unzip zlib1g-dev \
		file wget
else
	echo "  依赖齐全"
fi

# ---------------------------------------------------------------- 2. 拉源码
log "准备源码树 $VERSION"
if [ -d "$WORKDIR/.git" ]; then
	echo "  已存在，跳过 clone：$WORKDIR"
else
	git clone --depth=1 --single-branch -b "$VERSION" \
		https://github.com/openwrt/openwrt.git "$WORKDIR"
fi
cd "$WORKDIR"
[ -f target/linux/mediatek/image/filogic.mk ] || die "源码树不完整，缺 filogic.mk"

# ---------------------------------------------------------------- 2.5 装 feeds
# 首次 clone 之后 feeds/ 并不存在（仓库里只有 feeds.conf.default）。上游 luci
# （luci-mod-status / luci-base）就在 feeds/luci 里，而第 4.4 步要往
# feeds/luci 的文件里打补丁，所以必须**赶在打补丁之前**把 feeds 装好。
# （scripts/feeds 的 parse_config 在没有 feeds.conf 时会回落到 feeds.conf.default，
#   所以全新 clone 直接跑 update -a 可行。）
# 幂等：feeds/luci 已在就跳过 —— 本地反复编译几乎不额外花时间。
log "准备 feeds（luci / packages / routing …）"
if [ ! -d feeds/luci ]; then
	./scripts/feeds update -a
	./scripts/feeds install -a
else
	echo "  已存在，跳过：$WORKDIR/feeds/luci"
fi

# ---------------------------------------------------------------- 3. 放 DTS
log "安装设备树"
cp -v "$DTS_SRC" target/linux/mediatek/dts/mt7981b-aigo-ags21.dts

# ------------------------------------------------- 3.5 放 uci-defaults 迁移脚本
# 端口改名（lan2/lan3 -> lan1/lan2）后，已存在配置里的 br-lan ports 不会自动跟着变
# （/etc/config/network 只在不存在或为空时生成）。这个脚本在升级后首次开机跑一次，
# 把旧名字原地换成新名字；不装的话桥会去桥不存在的 lan3，那个 LAN 口直接失效。
log "安装 uci-defaults 迁移脚本"
UCI_SRC="$HERE/99-ags21-port-rename"
[ -f "$UCI_SRC" ] || die "找不到 $UCI_SRC"
UCI_DEST="target/linux/mediatek/filogic/base-files/etc/uci-defaults"
mkdir -p "$UCI_DEST"
install -m 0755 "$UCI_SRC" "$UCI_DEST/99-ags21-port-rename"
echo "  $(ls -l "$UCI_DEST/99-ags21-port-rename" | awk '{print $1, $NF}')"

# ------------------------------------- 3.52 放 LuCI 前端资源缓存清除脚本
# 目的：让 LuCI 的 ?v= 在**每次刷机后**都变，逼浏览器重新拉取 /luci-static/ 下的
#       全部资源。完整根因与出处见 build/99-ags21-luci-cachebust 文件头，简言之：
#         header.ut 的 ?v=<luci版本>-{{ pkgs_update_time }} 里的 pkgs_update_time
#         = /lib/apk/db/installed 的 mtime（runtime.uc:182）；
#         而镜像里所有文件的 mtime 都被 SOURCE_DATE_EPOCH 钉成固定值
#         （out/profiles.json 的 source_date_epoch，实测 1782737960）
#         ⇒ ?v= 永不变化 ⇒ 缓存清除完全失效 ⇒ 从上一版升级上来的浏览器
#         一直用缓存里那份**没有注入段**的旧 10_system.js ⇒ 首页「温度」整行不显示，
#         而且因为模块是 JS 发起的 fetch，硬刷新（Ctrl+F5）也不会去校验。
#        ⇒ 首启 touch 一下，?v= 变了，浏览器必然重取。
#        **这是"改完 10_system.js 却看不到变化"这类问题的通用解**，
#        不必再去改文件名、也不该让用户手动清缓存。
# 为什么不用改 SOURCE_DATE_EPOCH 的办法：会放弃可复现构建，且可能触发全量重编；
#        理由与代价对比写在那个脚本的注释里。
log "安装 uci-defaults 缓存清除脚本（让 LuCI 的 ?v= 逐次刷机失效）"
CB_SRC="$HERE/99-ags21-luci-cachebust"
[ -f "$CB_SRC" ] || die "找不到 $CB_SRC"
install -m 0755 "$CB_SRC" "$UCI_DEST/99-ags21-luci-cachebust"
echo "  $(ls -l "$UCI_DEST/99-ags21-luci-cachebust" | awk '{print $1, $NF}')"

# ------------------------------------------------- 3.55 放 board.d 无线默认值
# 目标：不保留配置刷完后，无线默认就是开的（SSID/密码见脚本里的注释）。
# 机制：/lib/wifi/mac80211.uc 生成 /etc/config/wireless 时，
#       wifi-iface 的 disabled 取 `defaults ? 0 : 1`，defaults 来自
#       /etc/board.json 的 wlan.defaults；我们这块板原本没有 wlan.defaults
#       ⇒ 生成的配置带 disabled '1' ⇒ 每次重置后要手动开无线。
#       所以要在 board.d 这一层（board.json 的产出方）补上。
# 为什么不能放 /etc/uci-defaults：那一步跑在 /etc/init.d/boot，
#       早于 /etc/config/wireless 的生成，uci set 会写在还不存在的配置上。
# 注意：board.d 脚本是被 board_detect 用 `(. "$a")` **source** 的，
#       只检查 `[ -s "$a" ]`（非空），理论上不要求执行位；
#       这里照样 install -m 0755，跟 04_defaults 等上游文件保持一致的观感。
log "安装 board.d 无线默认值（不保留配置也默认开无线）"
BD_SRC="$HERE/04-ags21-wifi-defaults"
[ -f "$BD_SRC" ] || die "找不到 $BD_SRC"
BD_DEST="target/linux/mediatek/filogic/base-files/etc/board.d"
mkdir -p "$BD_DEST"
install -m 0755 "$BD_SRC" "$BD_DEST/04-ags21-wifi-defaults"
echo "  $(ls -l "$BD_DEST/04-ags21-wifi-defaults" | awk '{print $1, $NF}')"

# ------------------------------------------- 3.6 本地包 + 第三方包放进源码树
# 两件事：
#   ① 本仓库自带的包（ags21_openwrt/packages/）—— 首页 CPU 使用率 / 温度面板
#   ② 官方 feed 里没有、必须从 ImmortalWrt 搬的包（ddns-go / luci-app-homeproxy /
#      luci-app-ddns-go），由 vendor.sh 按固定 commit 取并打最小补丁
#
# 位置很关键：必须在第 5 步 `make defconfig` 之前完成。否则这些包还没进 kconfig，
# 我们写进 .config 的那几行 CONFIG_PACKAGE_xxx=y 会被 defconfig 当成未知符号
# 而**静默丢掉** —— 表现就是"编译成功、刷进去却没有这个功能"。
log "安装本地包与第三方包"
LOCAL_PKG_DIR="$HERE/../packages"
[ -d "$LOCAL_PKG_DIR" ] || die "找不到本地包目录 $LOCAL_PKG_DIR"
for _d in "$LOCAL_PKG_DIR"/*/; do
	_n="$(basename "$_d")"
	rm -rf "$WORKDIR/package/$_n"
	cp -a "$_d" "$WORKDIR/package/$_n"
	echo "  本地包 $_n（$(find "$WORKDIR/package/$_n" -type f | wc -l) 个文件）"
done

bash "$HERE/vendor.sh" "$WORKDIR"

# 装进来的包必须真的被 kconfig 认出来，否则上面的 CONFIG_PACKAGE_* 全是无效配置
for _n in luci-app-ags21-dashboard ddns-go luci-app-ddns-go luci-app-homeproxy; do
	[ -f "$WORKDIR/package/$_n/Makefile" ] \
		|| die "package/$_n/Makefile 不存在，第 3.6 步没装成功"
done

# ---------------------------------------------------------------- 4. 打补丁
log "打补丁（幂等 + 锚点校验）"
python3 - "$WORKDIR" "$MK_ADD" "$HERE/ags21-status-rows.js" <<'PYEOF'
import pathlib, re, sys

root   = pathlib.Path(sys.argv[1])
mk_add = pathlib.Path(sys.argv[2]).read_text(encoding='utf-8')
rows   = pathlib.Path(sys.argv[3]).read_text(encoding='utf-8').strip('\n')

def apply(path, fn, desc):
    p = root / path
    if not p.exists():
        raise SystemExit('  [失败] 缺文件 %s' % path)
    src = p.read_text(encoding='utf-8')
    new, changed = fn(src)
    if changed:
        p.write_text(new, encoding='utf-8')
        print('  [改动] %-58s %s' % (path, desc))
    else:
        print('  [跳过] %-58s %s' % (path, desc + '（已打过）'))

# --- 4.1 filogic.mk：追加 Device/aigo_ags21 --------------------------------
def patch_filogic(src):
    if 'aigo_ags21' in src:
        return src, False
    if not src.endswith('\n'):
        src += '\n'
    return src + '\n' + mk_add, True

apply('target/linux/mediatek/image/filogic.mk', patch_filogic,
      '新增 Device/aigo_ags21')

# --- 4.2 02_network：单独给 aigo,ags21 加分支 ------------------------------
# 为什么不并进 cmcc,rax3000m 那条 case 列表：
#   共用条目只能跟 cmcc 一样（3 个 LAN），而 AGS21 是 2 个 LAN，端口名也不同。
#   case 里第一个匹配的分支生效，所以必须用独立分支，不能既加进列表又另写一个
#   同名分支（那样后者永远是死代码）。
# 分支内容必须与 dts 里声明的 label 严格一致：
#   WAN = eth1（gmac1 + SoC 内置 PHY），LAN = 面板 LAN1/LAN2 = MT7531 PHY1/PHY2
#   = dts 里 label 的 lan1/lan2（名字对齐面板丝印，不是「PHY 号 + 1」）。
#   不一致的后果不是"少个口"这么轻 —— br-lan 会去桥不存在的接口，桥起不来，
#   设备直接失去网络，只能靠串口救。
# 注意锚点不能只写 "\tcase $board in"：这个文件里有两个 case（第一个在
#   mediatek_setup_interfaces()，第二个在 mediatek_setup_macs()），
#   实测各出现一次。这里锚定到函数开头，只命中 interfaces 那一个。
BOARD_CASE = ('mediatek_setup_interfaces()\n'
              '{\n'
              '\tlocal board="$1"\n'
              '\n'
              '\tcase $board in\n')

# 当前版本的 aigo 分支（含注释）。改网口时这里和 dts 的 label 必须一起改。
AIGO_BLOCK = (
    '\taigo,ags21)\n'
    '\t\t# AGS21：1 WAN + 2 LAN（实测定稿，别照抄 cmcc 的 3 LAN）\n'
    '\t\t#   WAN = eth1（gmac1 + SoC 内置 GbE PHY，mdio 地址 0）\n'
    '\t\t#   LAN = 面板 LAN1/LAN2 = MT7531 PHY1/PHY2 -> dts 里 label 是 lan1 / lan2\n'
    '\t\t#（端口名对齐面板丝印，与上游 rax3000m 的做法相同：名字不是 PHY 号 + 1）\n'
    '\t\t# 必须与 target/linux/mediatek/dts/mt7981b-aigo-ags21.dts 严格一致！\n'
    '\t\t# 改名后已存在配置的迁移见 /etc/uci-defaults/99-ags21-port-rename\n'
    '\t\tucidef_set_interfaces_lan_wan "lan1 lan2" eth1\n'
    '\t\t;;\n'
)

def patch_02network(src):
    # 幂等 + 可升级：若已有 aigo 分支，整块换成当前版本。
    # 这一步是必需的 —— 早期固件留下的旧块（"lan1 lan2 lan3 lan4"）如果只是
    # 「看到 aigo,ags21) 就跳过」，会永远停在旧内容上，而 dts 已经只剩两个口，
    # br-lan 就会去桥不存在的 lan1/lan4。
    i = src.find('\taigo,ags21)\n')
    if i != -1:
        j = src.find('\t\t;;\n', i)
        if j == -1:
            raise SystemExit(
                '  [失败] 02_network 里 aigo,ags21 分支找不到结束标记（两个制表符 + ;;），请人工确认。')
        j += len('\t\t;;\n')
        if src[i:j] == AIGO_BLOCK:
            return src, False
        return src[:i] + AIGO_BLOCK + src[j:], True

    n = src.count(BOARD_CASE)
    if n != 1:
        raise SystemExit(
            '  [失败] 02_network 里锚点（mediatek_setup_interfaces + case）出现 %d 次，预期 1 次。\n'
            '         上游文本可能变了，请人工确认后再跑。' % n)
    return src.replace(BOARD_CASE, BOARD_CASE + AIGO_BLOCK, 1), True

apply('target/linux/mediatek/filogic/base-files/etc/board.d/02_network',
      patch_02network, '新增 aigo,ags21 网口分支')

# --- 4.3 platform.sh：并进 cmcc,rax3000m 的 3 条 case 列表 -------------------
# 这三处都是纯 case 列表（同样的处理动作），所以并进去是正确的：
#   platform_do_upgrade    -> fit_do_upgrade    （eMMC 上的 FIT 升级）
#   platform_check_image   -> fit_check_image
#   platform_copy_config   -> emmc_copy_config  （保留配置）
ANCHOR = '\tcmcc,rax3000m|\\\n'
INSERT = '\taigo,ags21|\\\n'

def patch_platform(src):
    if 'aigo,ags21|' in src:
        return src, False
    n = src.count(ANCHOR)
    if n != 3:
        raise SystemExit(
            '  [失败] platform.sh 里锚点 %r 出现 %d 次，预期 3 次。\n'
            '         上游文本可能变了，请人工确认后再跑。' % (ANCHOR.strip(), n))
    return src.replace(ANCHOR, INSERT + ANCHOR), True

apply('target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh',
      patch_platform, 'fit_do_upgrade / fit_check_image / emmc_copy_config')

# --- 4.4 luci-mod-status/10_system.js：把「温度」「CPU 使用率」并进系统面板 ----
# 为什么动 feeds/luci 里的文件：
#   参照物（ImmortalWrt 首页）里这两行是**「系统」面板内部的字段**，不是独立的
#   include 面板；而 include 目录里的面板之间没法互相插行，只能改这个文件的
#   fields 数组。面板级扩展照旧走 include 目录（我们原来的 15_/61_ 两个文件
#   就是那么做的，本版已删掉，改走这条路）。
# 为什么原位打补丁，而不是自己包再装一个同路径文件：
#   同名文件分属两个包时，谁覆盖谁取决于安装顺序，不可控；而且上游一升级，
#   我们的副本会**静默**过期（首页悄悄少一行，没人会发现）。
#   原位锚点式打补丁正相反：上游文本一变，这里立刻 die，不会悄悄失效。
LUCI_SYS_P = ('feeds/luci/modules/luci-mod-status/htdocs/luci-static/'
              'resources/view/status/include/10_system.js')

def patch_10system(src):
    # 幂等：注入段已经在里面就直接返回
    if 'AGS21 注入段' in src:
        return src, False

    def once(s, pattern, repl, what):
        new, n = re.subn(pattern, repl, s, flags=re.S)
        if n != 1:
            raise SystemExit(
                '  [失败] 10_system.js 里锚点「%s」命中 %d 次，预期 1 次。\n'
                '         上游 LuCI 的文本变了，请人工核对后再改这段补丁。'
                % (what, n))
        return new

    # ① 采集函数（温度 / CPU 使用率）插在 callSystemInfo 声明之后
    src = once(src,
               r"(var callSystemInfo = rpc\.declare\(\{\n"
               r"[\t ]*object: 'system',\n"
               r"[\t ]*method: 'info'\n"
               r"\}\);\n)",
               lambda m: m.group(1) + '\n' + rows + '\n',
               'callSystemInfo 声明块')

    # ② load() 里多取两样东西。
    #    上游 load() 的 Promise.all 原本 5 个元素：board(0) info(1) luciVersion(2)
    #    unixtime(3) uci.load(4)。我们把两个采集器插在 callGetUnixtime 之后、
    #    uci.load('system') 之前 ⇒ ags21Temps=data[4]、ags21CPUUsage=data[5]，
    #    uci.load 被顶到 data[6]。**别照抄成 data[5]/data[6]，那是差一位的错位**。
    src = once(src,
               r"(\n(\t+)L\.resolveDefault\(callGetUnixtime\(\), 0\),\n)",
               lambda m: (m.group(1) + m.group(2) + 'ags21Temps(),\n' +
                          m.group(2) + 'ags21CPUUsage(),\n'),
               'load() 里的 callGetUnixtime')

    # ③ render() 里把这两个新返回值接出来（索引与上面 ② 一致：4 / 5）
    src = once(src,
               r"\n([\t ]+)unixtime([\t ]*)=([\t ]*)data\[3\];\n",
               lambda m: ('\n%sunixtime%s=%sdata[3],\n'
                          '%sags21_temp%s=%sdata[4],\n'
                          '%sags21_cpu%s=%sdata[5];\n'
                          % (m.group(1), m.group(2), m.group(3),
                             m.group(1), m.group(2), m.group(3),
                             m.group(1), m.group(2), m.group(3))),
               'render() 里 data[3] 的解构')

    # ④ 温度行插在「架构」之后 —— 和参照的 ImmortalWrt 同一位置
    src = once(src,
               r"\n([\t ]+)_\('Architecture'\),([\t ]*)boardinfo\.system,\n",
               lambda m: ("\n%s_('Architecture'),%sboardinfo.system,\n"
                          "%s'温度',%sags21_temp,\n"
                          % (m.group(1), m.group(2), m.group(1), m.group(2))),
               'fields 里的 Architecture 行')

    # ⑤ CPU 使用率行追加在 fields 末尾（ImmortalWrt 也是放最后一行）
    src = once(src,
               r"\n([\t ]+)\)\s*:\s*null\n([\t ]+)\];\n",
               lambda m: ('\n' + m.group(1) + ') : null,\n' +
                          m.group(1) + "'CPU 使用率（%）',     ags21_cpu\n" +
                          m.group(2) + '];\n'),
               'fields 数组结尾（Load Average 的 ) : null）')

    return src, True

apply(LUCI_SYS_P, patch_10system, '系统面板注入「温度」「CPU 使用率」两行')

print()
print('  补丁后确认：')
PYEOF

grep -n "^define Device/aigo_ags21\|^TARGET_DEVICES += aigo" target/linux/mediatek/image/filogic.mk
grep -n "aigo,ags21" target/linux/mediatek/filogic/base-files/etc/board.d/02_network
echo "  platform.sh 命中 aigo,ags21 次数：$(grep -c 'aigo,ags21|' target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh)"

# DTS 里引用的所有 label，确认它们在整棵 dts 里都有定义（廉价的自检）
python3 - "$WORKDIR" <<'PYEOF'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
dts = (root / 'target/linux/mediatek/dts/mt7981b-aigo-ags21.dts').read_text(encoding='utf-8')
# 我们只能校验本文件内部的自洽性；mt7981b.dtsi 里的定义要等编 dtb 才知道
defined = set(re.findall(r'^\s*([a-z_][a-z0-9_]*):\s', dts, re.M))
used = set(re.findall(r'<&([a-z_][a-z0-9_]*)', dts))
missing = sorted(used - defined)
print('  本文件内定义的 label：%s' % (', '.join(sorted(defined)) or '无'))
print('  <&...> 引用但本文件没定义（应由 mt7981b.dtsi 提供，编 dtb 时才能验）：')
print('    %s' % (', '.join(missing) or '无'))
PYEOF

# 网口名一致性自检：02_network 写进 br-lan 的口，必须在 dts 里有同名 label。
# 不一致的后果不是「少个口」这么轻 —— br-lan 会去桥不存在的接口，桥起不来，
# 设备直接失去网络，只能靠串口救。这是本项目最致命的坑，所以每次编都强制校验。
python3 - "$WORKDIR" <<'PYEOF'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
dts = (root / 'target/linux/mediatek/dts/mt7981b-aigo-ags21.dts').read_text(encoding='utf-8')
net = (root / 'target/linux/mediatek/filogic/base-files/etc/board.d/02_network').read_text(encoding='utf-8')

labels = set(re.findall(r'label\s*=\s*"(lan\d+)"', dts))

blk = re.search(r'\taigo,ags21\)\n(.*?)\t\t;;\n', net, re.S)
if not blk:
    raise SystemExit('  [失败] 02_network 里找不到 aigo,ags21 分支')
m = re.search(r'ucidef_set_interfaces_lan_wan\s+"([^"]*)"\s+"?([^"\s]+)"?', blk.group(1))
if not m:
    raise SystemExit('  [失败] aigo 分支里没有 ucidef_set_interfaces_lan_wan')

lan = m.group(1).split()
wan = m.group(2)
bad = [p for p in lan if p not in labels]
print('  02_network: LAN = %s    WAN = %s' % (' '.join(lan), wan))
print('  dts 里的 LAN label: %s' % (', '.join(sorted(labels)) or '无'))
if bad:
    raise SystemExit('  [失败] 这些 LAN 口在 dts 里没有对应 label：%s\n'
                     '         dts 里只有：%s' % (' '.join(bad), ', '.join(sorted(labels))))
if sorted(lan) != sorted(labels):
    raise SystemExit('  [失败] 02_network 的 LAN 列表 %s 与 dts 的 LAN label %s 不一致'
                     % (lan, sorted(labels)))
if wan in labels:
    raise SystemExit('  [失败] WAN 设备 %r 与某个 LAN label 重名' % wan)
print('  [OK] 02_network 与 dts 的网口名一致（LAN %s / WAN %s）' % (' '.join(lan), wan))
PYEOF

# 无线默认值自检：「不保留配置也开无线」全靠 board.json 里的 wlan.defaults。
# 少了它，mac80211.uc 生成的 wifi-iface 会带 disabled '1'，而且**编译期完全
# 看不出来**（镜像照样编过、刷进去才发现无线是关的）。所以每次编都验一遍。
python3 - "$WORKDIR" <<'PYEOF'
import pathlib, re, sys
p = (pathlib.Path(sys.argv[1]) /
     'target/linux/mediatek/filogic/base-files/etc/board.d/04-ags21-wifi-defaults')
if not p.exists() or p.stat().st_size == 0:
    raise SystemExit('  [失败] %s 不存在或为空（第 3.55 步没装成功）' % p)
src = p.read_text(encoding='utf-8')

blk = re.search(r'aigo,ags21\)\n(.*?)\nesac\n', src, re.S)
if not blk:
    raise SystemExit('  [失败] board.d 无线默认值脚本里没有 aigo,ags21 分支')
body = blk.group(1)

bands = re.findall(r'ucidef_set_wireless\s+(\S+)', body)
if '2g' not in bands or '5g' not in bands:
    raise SystemExit('  [失败] 缺 2g/5g 的 ucidef_set_wireless（实际：%s）'
                     % (','.join(bands) or '无'))
if 'ucidef_set_country' not in body:
    raise SystemExit('  [失败] 没设 country —— mac80211.uc 里 '
                     '`if (!country && band_name != \'2g\') defaults = null`，'
                     '5G 的 defaults 会被丢掉、5G 仍然不启用')
# 用户 2026-10-13 明确要求「用 OpenWrt 默认设置、无密码」——这里防止
# 以后手滑把 psk2/密码又写回去（写回去会被静默接受，只有刷完机才发现）。
# 注意用 [ \t] 而不是 \s：\s 会跨行，两条只带 ssid 的 ucidef_set_wireless
# 会被误判成「后面还有 encryption/key」（实测踩过这个假阳性）。
if 'psk2' in body or re.search(
        r'ucidef_set_wireless[ \t]+\S+[ \t]+\S+[ \t]+\S+', body):
    raise SystemExit('  [失败] 无线默认值里给了 encryption/key —— '
                     '当前要求是「OpenWrt 默认设置，无密码」，'
                     '确实要改成加密网络的话，请先改掉 build-ags21.sh 里的这条断言')
print('  [OK] 无线默认值：bands=%s，country 已设，无密码（上游默认 SSID）'
      % ','.join(bands))
PYEOF

# 第 4.4 步的注入也要能被确认（和上面几处自检一个路子）。
# 这两行失效的表现是「首页少两行」—— 编译期完全看不出来，所以必须在这里挡。
python3 - "$WORKDIR" <<'PYEOF'
import pathlib, sys
p = (pathlib.Path(sys.argv[1]) / 'feeds/luci/modules/luci-mod-status/htdocs/'
     'luci-static/resources/view/status/include/10_system.js')
src = p.read_text(encoding='utf-8')
need = ['AGS21 注入段', "'温度'", "'CPU 使用率（%）'", 'ags21Temps(),', 'ags21CPUUsage(),']
missing = [n for n in need if n not in src]
if missing:
    raise SystemExit('  [失败] 10_system.js 注入不完整，缺：%s' % ', '.join(missing))
if src.count('AGS21 注入段') != 2:
    raise SystemExit('  [失败] 10_system.js 里注入段标记出现 %d 次，预期 2 次（首尾各一）'
                     % src.count('AGS21 注入段'))

# --- 索引一致性硬校验（这条是 2026-10-13 真踩过的坑）---
# 上游 load() 的 Promise.all 原本 5 个元素，我们把两个采集器插在 callGetUnixtime
# 之后 ⇒ ags21Temps=data[4]、ags21CPUUsage=data[5]，uci.load 被顶到 data[6]。
# 一旦 render() 里写成 data[5]/data[6]，**编译不报错、首页也不报错**，
# 只是「温度」行会显示 CPU 使用率、「CPU 使用率」行显示一个 uci 对象 —— 极难发现。
# 所以这里不是查字面量，而是真的把 load() 的实参拆出来数一遍，再和 render() 的
# 解构索引对比。
import re as _re
_m = _re.search(r'load:\s*function\s*\(\)\s*\{\s*return Promise\.all\(\[(.*?)\]\)',
                src, _re.S)
if not _m:
    raise SystemExit('  [失败] 10_system.js 里找不到 load() 的 Promise.all，索引无法校验')
_body, _depth, _cur, _args = _m.group(1), 0, '', []
for _ch in _body:
    if _ch in '([{':
        _depth += 1
    elif _ch in ')]}':
        _depth -= 1
    if _ch == ',' and _depth == 0:
        _args.append(_cur); _cur = ''
    else:
        _cur += _ch
_args.append(_cur)


def _idx_of(_frag):
    _hits = [i for i, a in enumerate(_args) if _frag in a]
    if len(_hits) != 1:
        raise SystemExit('  [失败] load() 里 %s 出现 %d 次，预期 1 次'
                         % (_frag, len(_hits)))
    return _hits[0]


_t_i, _c_i = _idx_of('ags21Temps()'), _idx_of('ags21CPUUsage()')
_mt = _re.search(r'ags21_temp\s*=\s*data\[(\d+)\]', src)
_mc = _re.search(r'ags21_cpu\s*=\s*data\[(\d+)\]', src)
if not _mt or not _mc:
    raise SystemExit('  [失败] 10_system.js 里找不到 ags21_temp= / ags21_cpu= 的解构')
if int(_mt.group(1)) != _t_i or int(_mc.group(1)) != _c_i:
    raise SystemExit(
        '  [失败] 索引错位！load() 里 ags21Temps=data[%d]、ags21CPUUsage=data[%d]，'
        '但 render() 解构成 ags21_temp=data[%s]、ags21_cpu=data[%s]。\n'
        '         这种错编译不报错，只会让「温度」行显示 CPU 使用率，'
        '请把 build-ags21.sh 第 ③ 步的 data[N] 改对。'
        % (_t_i, _c_i, _mt.group(1), _mc.group(1)))
print('  [OK] 索引一致：ags21Temps=data[%d]、ags21CPUUsage=data[%d]' % (_t_i, _c_i))

print('  [OK] 10_system.js 已注入「温度」「CPU 使用率」两行（%d 字节）' % len(src))
PYEOF

if [ "$STAGE" = "sync" ]; then
	log "stage=sync 完成（拉源码 + 打补丁）"
	exit 0
fi

# ---------------------------------------------------------------- 5. 配置
log "生成 .config（aigo_ags21 + LuCI）"
# 必选配置清单：缺哪行补哪行，已存在的不动。
# 原来是「只有 .config 里还没有 DEVICE_aigo_ags21 时才整段写入」，副作用是
# 之后想加配置脚本什么都不做 —— 改成逐行补，幂等且能真正改到配置。
REQUIRED_CONF=(
	'CONFIG_TARGET_mediatek=y'
	'CONFIG_TARGET_mediatek_filogic=y'
	'CONFIG_TARGET_mediatek_filogic_DEVICE_aigo_ags21=y'
	# ---- LuCI 网页界面 ----
	# luci 是元包，自动带出 luci-base / luci-mod-admin-full / luci-mod-network
	# / luci-mod-status / luci-mod-system / luci-app-firewall
	# / luci-app-package-manager / luci-theme-bootstrap
	'CONFIG_PACKAGE_luci=y'
	'CONFIG_PACKAGE_luci-ssl=y'
	# 中文界面。实测的坑：只写 CONFIG_PACKAGE_luci-i18n-base-zh-cn=y 是没用的，
	#   make defconfig 会把它丢掉 —— 那个符号的默认值被写成
	#   `default LUCI_LANG_zh_Hans||(ALL&&m)`，
	# 必须打开这个语言开关，它才会连带把 luci-i18n-base-zh-cn /
	#   luci-i18n-firewall-zh-cn / luci-i18n-package-manager-zh-cn 一起选上。
	'CONFIG_LUCI_LANG_zh_Hans=y'
	# ---- 设备上的 apk 仓库列表 ----
	# PER_FEED_REPO=y 时每个 feed 在 /etc/apk/repositories.d/ 下是一条独立源。
	# 这几个 FEED_* 不打开的话，刚刷完的机器没有任何软件源，apk add 装不了东西。
	'CONFIG_PER_FEED_REPO=y'
	'CONFIG_FEED_packages=y'
	'CONFIG_FEED_luci=y'
	'CONFIG_FEED_routing=y'
	'CONFIG_FEED_telephony=y'
	'CONFIG_FEED_video=y'
	# ---- 应用：WireGuard ----
	# 官方 feed 直接可用。luci-proto-wireguard 的二维码是纯前端实现的
	# （依赖 luci-lib-uqr），所以不需要 qrencode。
	'CONFIG_PACKAGE_kmod-wireguard=y'
	'CONFIG_PACKAGE_wireguard-tools=y'
	'CONFIG_PACKAGE_luci-proto-wireguard=y'
	# 注意：这里原写过 luci-i18n-wireguard-zh-cn=y，但它是**无效符号** ——
	#   官方 luci-proto-wireguard 目录下根本没有 po/，也就没有对应 i18n 包，
	#   defconfig 会把这个未知符号静默丢掉（现在下面的回读校验会抓到这种）。
	#   WireGuard 界面的中文来自 luci-base 的 base.po（域名 base），无需独立翻译包。
	# ---- 应用：ddns-go（官方 feed 没有，见 vendor.sh）----
	# 'CONFIG_PACKAGE_ddns-go=y'
	# 'CONFIG_PACKAGE_luci-app-ddns-go=y'
	# 'CONFIG_PACKAGE_luci-i18n-ddns-go-zh-cn=y'
	# ---- 应用：homeproxy（官方 feed 没有，见 vendor.sh）----
	# homeproxy 的 LUCI_DEPENDS 里已经声明了 sing-box / firewall4 /
	# kmod-nft-tproxy / ucode-mod-digest，下面这些是显式再写一遍：
	# 一来让人一眼看清固件里到底塞了什么，二来防上游改依赖时我们不知不觉掉功能。
	# sing-box 走官方 feed（1.12.x），homeproxy 只需要它提供 /usr/bin/sing-box。
	# 'CONFIG_PACKAGE_luci-app-homeproxy=y'
	# 'CONFIG_PACKAGE_luci-i18n-homeproxy-zh-cn=y'
	# 'CONFIG_PACKAGE_sing-box=y'
	'CONFIG_PACKAGE_luci-app-upnp=y'
	'CONFIG_PACKAGE_kmod-nf-conntrack-netlink=y'
	'CONFIG_PACKAGE_kmod-nft-tproxy=y'
	'CONFIG_PACKAGE_kmod-nft-socket=y'
	'CONFIG_PACKAGE_kmod-tun=y'
	'CONFIG_PACKAGE_kmod-inet-diag=y'
	'CONFIG_PACKAGE_firewall4=y'
	'CONFIG_PACKAGE_ucode-mod-digest=y'
	# ucode-mod-math：homeproxy 的 root/etc/homeproxy/scripts/generate_client.uc
	#   第 11 行 `import { isnan } from 'math'`（第 177 行真的在调用它），
	#   但上游 LUCI_DEPENDS 只声明了 +ucode-mod-digest，**漏了 math**。
	#   现在能跑只是因为 luci-base 兜住了：luci-base 自己的 ucode/dispatcher.uc
	#   也 `import { rand } from 'math'`，且它的 DEPENDS 里确有 +ucode-mod-math。
	#   把这个依赖链摆到明面上、显式写一行，是不想把「巧合」当保证 ——
	#   上游哪天不再顺带带上，homeproxy 的客户端配置生成会直接报
	#   `Unable to resolve module 'math'` 而失败。
	'CONFIG_PACKAGE_ucode-mod-math=y'
	# ---- sing-box 编译特性（homeproxy 的服务端 ACME 必须靠它）----
	# 官方 feed 的 sing-box 把 ACME / DHCP 做成**默认关闭**的可选 tag，而 ImmortalWrt
	# 自家的 sing-box 是默认编进去的（它的 GO_PKG_TAGS 直接写死 with_acme,with_dhcp,…）。
	# homeproxy 的 generate_server.uc 会生成 `acme: {...}` 块（服务端自动申请 TLS
	# 证书），sing-box 若没编 with_acme，启用 ACME 时会因不识别该字段而启动失败。
	# 版本说明：官方 feed 是 1.12.17、ImmortalWrt 是 1.12.25，同属 1.12.x，
	#   配置格式兼容（homeproxy 里那句「leave for sing-box 1.13.0」的注释正说明
	#   它当前面向 1.12.x），所以只需补齐缺失的 tag，不必换整包。
	# 'CONFIG_SINGBOX_WITH_ACME=y'
	# 'CONFIG_SINGBOX_WITH_DHCP=y'
	# ---- qrencode：命令行二维码工具 ----
	# 注意：LuCI 的 WireGuard 界面二维码是纯前端的 luci-lib-uqr（µQR，生成 SVG），
	#   本来就**不需要** qrencode。这里装的是命令行 /usr/bin/qrencode，给脚本/终端用，
	#   例如 qrencode -t ANSIUTF8 'text' 直接在终端打出可扫的二维码。
	#   QRENCODE_PNG=y 才支持 -o xxx.png 输出图片（会连带拉上 libpng）；
	#   不想要 PNG 就把那一行删掉，qrencode 仍能输出 ANSI/UTF8/SVG。
	'CONFIG_PACKAGE_libqrencode=y'
	'CONFIG_QRENCODE_PNG=y'
	'CONFIG_PACKAGE_qrencode=y'
	# ---- 本地面板：首页加 CPU 使用率 / 温度 ----
	'CONFIG_PACKAGE_luci-app-ags21-dashboard=y'
)
for _line in "${REQUIRED_CONF[@]}"; do
	if grep -qxF "$_line" .config 2>/dev/null; then
		continue
	fi
	echo "  [补配置] $_line"
	printf '%s\n' "$_line" >> .config
done
unset _line

# feeds 已在第 2.5 步装好（第 4.4 步要往 feeds/luci 里打补丁，必须先有它）

make defconfig

# 回读校验（2026-10-13 加）：make defconfig 会把它**不认识**的符号静默丢弃 ——
#   上游改名 / 包被移除 / 依赖不满足（例如某个包根本没有 po/，对应的 i18n 包
#   就不存在）都会让上面「补配置」那一步白做，而编译照样成功、日志照样漂亮，
#   只有刷完机发现少功能才知道。实测踩过一次：luci-i18n-wireguard-zh-cn。
#   所以这里逐行回读，缺一条就退出，把问题挡在编译之前而不是刷机之后。
_missing=()
for _line in "${REQUIRED_CONF[@]}"; do
	grep -qxF "$_line" .config || _missing+=("$_line")
done
if [ "${#_missing[@]}" -gt 0 ]; then
	warn "以下必选配置在 make defconfig 之后消失了（符号不存在或依赖不满足）："
	printf '     %s\n' "${_missing[@]}" >&2
	die "有 ${#_missing[@]} 项必选配置没进 .config，固件会缺功能"
fi
echo "  [OK] 必选配置回读通过：${#REQUIRED_CONF[@]} 项都在 .config 里"
unset _line _missing

echo "  最终配置："
grep -E 'CONFIG_TARGET_mediatek_filogic_DEVICE_aigo_ags21|CONFIG_TARGET_ROOTFS_PARTSIZE|^CONFIG_PACKAGE_luci|^CONFIG_LUCI_LANG_' .config || true

if [ "$STAGE" = "dtb" ]; then
	log "stage=dtb：只验设备树（主机 cpp + dtc，几秒出结果，不编内核）"
	# 为什么不用 make target/linux/compile：
	#   dtb 编译只需要主机 cpp 和 dtc 两个程序，根本不需要交叉工具链。
	#   跑 target/linux/compile 会连带编 30 分钟内核，才发现一棵 dts 写错了。
	# 另外 OpenWrt 25.12 已经没有 tools/dtc 这个包了（dtc 由主机提供，
	#   Ubuntu 上就是 /usr/bin/dtc），所以这里先找 staging，再退回系统的。
	DTC="$(command -v dtc 2>/dev/null || true)"
	if [ -x "$WORKDIR/staging_dir/host/bin/dtc" ]; then
		DTC="$WORKDIR/staging_dir/host/bin/dtc"
	fi
	if [ -z "$DTC" ]; then
		die "找不到 dtc。Ubuntu 上：sudo apt install device-tree-compiler"
	fi
	echo "  dtc      : $DTC"

	KDIR="$(ls -d "$WORKDIR"/build_dir/target-*/linux-mediatek_filogic/linux-* 2>/dev/null | head -1 || true)"
	if [ -z "$KDIR" ]; then
		warn "还没有内核树，先跑一次 prepare（几分钟）"
		make -j"$(nproc)" target/linux/prepare 2>&1 | tail -3
		KDIR="$(ls -d "$WORKDIR"/build_dir/target-*/linux-mediatek_filogic/linux-* 2>/dev/null | head -1 || true)"
	fi
	[ -n "$KDIR" ] || die "prepare 之后仍找不到内核树"
	echo "  内核树   : $(basename "$KDIR")"

	cp -f "$WORKDIR/target/linux/mediatek/dts/mt7981b-aigo-ags21.dts" \
	      "$KDIR/arch/arm64/boot/dts/mediatek/"

	PRE=/tmp/ags21.pre.dts
	OUT=/tmp/ags21-check.dtb
	DLOG=/tmp/ags21-dtc.log

	( cd "$KDIR" && cpp -nostdinc \
		-I scripts/dtc/include-prefixes \
		-I arch/arm64/boot/dts \
		-I arch/arm64/boot/dts/mediatek \
		-I include \
		-undef -D__DTS__ -x assembler-with-cpp \
		arch/arm64/boot/dts/mediatek/mt7981b-aigo-ags21.dts -o "$PRE" )
	echo "  预处理   : $(wc -l < "$PRE") 行"

	rm -f "$OUT"
	"$DTC" -I dts -O dtb -o "$OUT" "$PRE" 2>"$DLOG" || true

	# mt7981b.dtsi 是内核自带的，它的既有告警与我们无关，单独滤掉
	if grep -v 'mt7981b\.dtsi' "$DLOG" | grep -q .; then
		warn "与我们 dts 相关的告警："
		grep -v 'mt7981b\.dtsi' "$DLOG" | head -20
	else
		echo "  告警     : 无（mt7981b.dtsi 自带的告警已忽略）"
	fi

	if [ ! -f "$OUT" ]; then
		warn "dtb 没生成，dtc 完整输出："
		cat "$DLOG"
		exit 1
	fi
	echo
	echo "  ✓ 设备树编译通过：$(wc -c < "$OUT") 字节"

	$DTC -I dtb -O dts "$OUT" > /tmp/ags21-check.dts 2>/dev/null || true
	echo
	echo "  回读核对："
	printf '    %-34s %s\n' "model = \"AIGO AGS21\"" "$(grep -c 'AIGO AGS21' /tmp/ags21-check.dts)"
	printf '    %-34s %s\n' 'compatible aigo,ags21' "$(grep -c 'aigo,ags21' /tmp/ags21-check.dts)"
	printf '    %-34s %s\n' 'memory@40000000 (1GB)' "$(grep -c 'memory@40000000' /tmp/ags21-check.dts)"
	printf '    %-34s %s\n' 'gpio-leds / gpio-keys' "$(grep -c 'gpio-leds\|gpio-keys' /tmp/ags21-check.dts)"
	printf '    %-34s %s\n' 'switch port lan label' "$(grep -c 'label = "lan' /tmp/ags21-check.dts)"
	printf '    %-34s %s\n' 'eMMC partname (factory/production)' "$(grep -c 'partname = ' /tmp/ags21-check.dts)"
	printf '    %-34s %s\n' 'rootdisk' "$(grep -c 'rootdisk' /tmp/ags21-check.dts)"
	echo
	echo "  反编译结果已保存：/tmp/ags21-check.dts"
	exit 0
fi

# ---------------------------------------------------------------- 6. 编译
log "开工编译（第一次要下工具链和源码包，1-3 小时不等）"
START=$(date +%s)
# 用 world，不要手搓步骤。world 定义在顶层 Makefile:133：
#   prepare → target/compile → package/compile → package/install
#           → target/install → package/index → checksum
#
# 两个坑（都是实测踩过的）：
#   ① 顺序不能省。target/install 会去生成 root.squashfs，而
#      build_dir/target-*/root-mediatek 这个目录是 package/install 填出来的。
#      少了 package 那两步，就会在 root.squashfs 处报
#      "Cannot stat source directory .../root-mediatek" 而失败。
#   ② 不传 PROFILE=：.config 里已经用 DEVICE_ 语法精确选了 aigo_ags21，
#      再传 PROFILE 会触发一次 defconfig 重写，反而可能把设备选择冲掉。
#
# 这里不再单独跑 make image：镜像生成属于 target/install 的一部分，world 已覆盖。
#
# 第 4.4 步改的是 feeds/luci 里的文件，而 luci 包是「无源码」包（直接 copy
# htdocs），OpenWrt 的 .built 戳**不会**因为 htdocs 变了而失效 —— 不强制清一次
# 的话，编译照样成功，镜像里却还是旧的 10_system.js（首页少两行）。
# 所以这里显式清掉 luci-mod-status 的构建戳和已生成的包，逼它重打。
# （清的是构建产物，源码树里的改动不受影响。）
log "强制 luci-mod-status 重编（第 4.4 步改了它的 htdocs）"
rm -rf build_dir/target-*/luci-mod-status* 2>/dev/null || true
rm -f  bin/packages/*/*/luci-mod-status_*  bin/packages/*/*/luci-mod-status-* 2>/dev/null || true
rm -f  bin/targets/*/*/packages/luci-mod-status_* 2>/dev/null || true
echo "  已清除 luci-mod-status 的构建戳与旧包"

make -j"$(nproc)" world
echo "  耗时 $(( ($(date +%s) - START) / 60 )) 分钟"

# ---------------------------------------------------------------- 7. 结果
log "产物"
ITB=$(ls -1 bin/targets/mediatek/filogic/*aigo_ags21*sysupgrade.itb 2>/dev/null | head -1 || true)
if [ -z "$ITB" ]; then
	warn "没找到 sysupgrade.itb，bin/targets/mediatek/filogic/ 内容："
	ls -l bin/targets/mediatek/filogic/ | head -30
	exit 1
fi
ls -l "$ITB"
echo
sha256sum "$ITB"
echo
python3 "$HERE/fit_configs.py" "$ITB"
