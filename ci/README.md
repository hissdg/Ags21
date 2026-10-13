# AGS21 —— GitHub Actions 云编译

> **状态（2026-10-13）**：**已启用。** 仓库 `kunude/Ags21`（Public），
> `stage=sync` 已跑通（约 4 分钟、全绿 ⇒ 三处补丁在上游 v25.12.5 上仍能干净应用）。
> `stage=all` 尚未跑过 —— 日常迭代仍优先走本地，理由见 §9。

---

## 1. 它解决什么问题

本地编译（WSL，20 核）**首次全量**要 1-3 小时，跑的时候整台机器被占满。
（若本地已有**预热构建树**，后续增量只要 **2 分钟左右** —— 2026-10-13 实测
`--stage=all` 为 2 分 0.5 秒。所以"本地够快"只在增量成立；换机器或清树后又回到 1-3 小时。）
而移植定稿之后，"改一行 DTS 重新出包"这种事会反复发生。

云编译把这件事变成点一下按钮：

- 不占本机
- 产物留 90 天，随时重下
- GitHub 在美国，拉 `github.com/openwrt/openwrt` 和 `downloads.openwrt.org` 都比国内快
- ccache 命中时，改一行 DTS 的重新出包只要十几分钟

**补丁逻辑只有一份。** `ci/ci-build.sh` 不自己实现「放 dts / 改 filogic.mk / 改 02_network /
改 platform.sh」，而是直接调 `build/build-ags21.sh`。所以「本地编出来」和「云编出来」是同一个
东西 —— 不会出现两边补丁悄悄分叉、本地能编云上编不过的情况。

---

## 2. 文件清单

| 文件 | 作用 |
|---|---|
| `.github/workflows/build-ags21.yml` | workflow 编排：腾磁盘 → 装依赖 → 存取缓存 → 调 `ci-build.sh` → 传产物 |
| `ci/ci-build.sh` | 构建入口。CI 和本地共用，本地也能跑（`bash ci/ci-build.sh --dtb`） |
| `ci/config.seed` | 配置种子（纯 ASCII）。**要加包、改参数就改这里** |

被复用、没有复制一份的：`build/build-ags21.sh`（补丁 + 编译）、`build/filogic.mk.add`、
`build/fit_configs.py`、`mt7981b-aigo-ags21.dts`，以及首启脚本
`build/99-ags21-luci-cachebust`（随 target 覆盖层进镜像；它解决的问题见
`明日操作卡.md` 10.8 节 —— 不改前端代码却看不到页面变化时，先看那一节）。

---

## 3. 启用步骤

### 3.1 建仓库

**用 Public。** 私有仓库的 Actions 有月度分钟配额（约 2000 分钟），而一次冷跑就要
1.5-3 小时，两三次就烧掉大半；公开仓库的 Actions 是免费的、不限时长。

> 本次实际建的是 **`kunude/Ags21`**。⚠ **规范名是大写 `Ags21`** ——
> GitHub 仓库名大小写不敏感，小写 `ags21` 只是个跳转；`git remote` 一定要写规范名，
> 否则每次 push 都会多一句 `This repository moved... Ags21.git` 提示。

### 3.2 push 之前 —— 先看这一节

这个仓库一旦公开，进去的东西就是全世界可见、可被搜索引擎索引的。`.gitignore` 已经挡住了
明确危险的：

- `ags21_backup/` —— 全分区备份（含 GPT、u-boot-env、`factory` 里的 WiFi 校准数据）
- `_uboot_env.txt` —— U-Boot 环境变量（含设备 MAC、序列号）
- `*.log` —— 串口日志里就有 MAC
- `official-25.12.5/` —— 几十 MB 上游二进制，随时能重下

**但下面这两个文档你得自己看一眼**，`.gitignore` 没有排除它们（它们有技术价值，
记录了踩过的坑）：

```
AGS21_OpenWrt_移植方案.md
明日操作卡.md
```

确认里面没有你的 MAC 地址、序列号、Wi-Fi 密码之类，再决定推不推。不确定就先删掉。

```bash
git status                        # 看一眼到底要提交什么
git diff --cached | grep -iE "mac|[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}"
```

### 3.3 初始化并推

```bash
cd ags21_openwrt
git init -b main
git config user.name  "kunude"
git config user.email "kunude@users.noreply.github.com"
git add .
git status                        # ← 再确认一次
git commit -m "AGS21: OpenWrt 25.12.5 移植 + 云编译流水线"
git remote add origin git@github.com:kunude/Ags21.git
git push -u origin main
```

### 3.4 跑

第一次**先点 `stage=sync`**（几十秒），确认三处补丁在上游文件上还能干净应用。
这一步过不了，跑三小时完整编译是白费。

```
Actions → Build AGS21 OpenWrt → Run workflow → stage 选 sync → 绿色通过
                                     ↓
                              再选 all 跑完整编译
```

---

## 4. 配置怎么改

只改 `ci/config.seed`。它是**纯 ASCII** 的（整份喂给 Kconfig 解析器，runner 的
locale 可能是 C，所以中文说明一律写成 `#` 注释或在本文里）。顶部几行含义：

| 行 | 含义 |
|---|---|
| `CONFIG_TARGET_mediatek=y`<br>`CONFIG_TARGET_mediatek_filogic=y` | 目标平台：MT7981/MT7986 这一代 WiFi6 |
| `CONFIG_TARGET_mediatek_filogic_DEVICE_aigo_ags21=y` | 只选 AGS21 一个设备 |
| `CONFIG_TARGET_ROOTFS_PARTSIZE=448` | **别乱改。** `filogic.mk` 里 `IMAGE_SIZE := $(expr 64 + 这个值)m`，448 才等于 512 MiB，正好对上官方 GPT 的 `production`（448M@64M）分区。改了 sysupgrade 会写到分区外 |
| `CONFIG_CCACHE=y` | 云编译的意义所在，别删 |
| `CONFIG_PACKAGE_luci=y`<br>`CONFIG_PACKAGE_luci-ssl=y` | LuCI 网页界面。`luci` 是元包，会带出 `luci-base`、`luci-mod-admin-full`、`luci-mod-network/-status/-system`、`luci-app-firewall`、`luci-app-package-manager`、`luci-theme-bootstrap`；`luci-ssl` 是 uhttpd + 自签证书，走 443 |
| `CONFIG_LUCI_LANG_zh_Hans=y` | 中文界面。**不是**选 `luci-i18n-base-zh-cn` 就行 —— 见 4.2 |
| `CONFIG_PER_FEED_REPO=y`<br>`CONFIG_FEED_packages/luci/routing/telephony/video=y` | 设备上的 apk 源列表。这组默认就是 `y`，显式写是为了不依赖旧 `.config` 的残留 —— 见 4.3 |

再往下是**应用包清单**，与 `build/build-ags21.sh` 里的 `REQUIRED_CONF`
**一一对应，改一处必须同步另一处**：WireGuard 全家桶、ddns-go、homeproxy
（含 `CONFIG_SINGBOX_WITH_ACME=y` / `_DHCP=y` —— homeproxy 服务端自动签证书的硬需求）、
`ucode-mod-math` / `firewall4`（homeproxy 上游漏声明的依赖，见下）、
qrencode、以及本仓库自带的首页面板包 `luci-app-ags21-dashboard`（两块面板：
CPU 使用率 + 温度，前者排在系统/内存之间，后者跟在「无线」后面）。
每一项「为什么」都写在 `config.seed` 自己的注释里。

> **为什么连 `ucode-mod-math` 都要显式写**：homeproxy 的
> `etc/homeproxy/scripts/generate_client.uc:11` 有 `import { isnan } from 'math'`，
> 但它的 `LUCI_DEPENDS` 只列了 `+ucode-mod-digest`，**漏了 math**。
> 现在能跑只是因为 `luci-base` 顺带带上了（luci-base 自己的 `dispatcher.uc`
> 也 import math）。「别的包碰巧带上」不算依赖声明，上游一变就悄悄掉功能 ——
> 所以显式钉住。真缺了的症状：启用 homeproxy 客户端时报
> `Unable to resolve module 'math'`。

加软件包就往这里追加 `CONFIG_PACKAGE_xxx=y`，然后 `make defconfig` 会自己补齐依赖。
但注意 **defconfig 会静默丢掉它不认识的符号**（实测：`luci-i18n-wireguard-zh-cn`
根本不存在，写了等于白写），所以 `build-ags21.sh` 现在会在 `make defconfig` **之后**
逐行回读 `REQUIRED_CONF`，缺一项就报错退出。

> **一个容易误判的点**：`filogic.mk` 里 `DEVICE_PACKAGES := kmod-mt7915e ...` 那串，
> **不会**以 `CONFIG_PACKAGE_kmod-mt7915e=y` 的形式出现在 `.config` 里 —— `include/image.mk`
> 是用 `CONFIG_TARGET_DEVICE_PACKAGES_<target>_<device>` 传字符串的。
> 所以「.config 里没有 kmod-mt7915e」不代表配置没生效。

### 4.1 feeds（原来那段死代码已修）

`build/build-ags21.sh` 里原来是这样写的：

```bash
if [ -d feeds ] && [ ! -d feeds/luci ]; then
    ./scripts/feeds update -a
    ./scripts/feeds install -a
fi
```

首次 clone 之后 `feeds/` 目录根本不存在（仓库里只有 `feeds.conf.default`），条件为假；
之后 `feeds/luci` 已经存在，条件仍为假 —— 所以它**一次也不会执行**，是死代码。
而 LuCI 就在 `feeds/luci` 里，不装 feeds 就选不到 `CONFIG_PACKAGE_luci`。

已改成：

```bash
if [ ! -d feeds/luci ]; then
    ./scripts/feeds update -a
    ./scripts/feeds install -a
fi
```

幂等，装过就跳过。全新 clone 直接跑也没问题：`scripts/feeds` 的 `parse_config()`
在没有 `feeds.conf` 时会回落到 `feeds.conf.default`（读源码确认，第 89-94 行），
所以不需要先手工 `cp feeds.conf.default feeds.conf`。

### 4.2 中文界面：为什么不能直接选 `luci-i18n-base-zh-cn`

**实测的坑。** 往 `.config` 里写 `CONFIG_PACKAGE_luci-i18n-base-zh-cn=y`，
`make defconfig` 会**默默把它丢掉**，中文界面不会出现。

原因在 LuCI 生成的符号定义里（`tmp/.config-package.in`）：

```
config PACKAGE_luci-i18n-base-zh-cn
	tristate
	default y if DEFAULT_luci-i18n-base-zh-cn
	default LUCI_LANG_zh_Hans||(ALL&&m)     <-- 门控在这一行
	select PACKAGE_libc
	depends on PACKAGE_luci-base
```

语言开关是 `menu "Translations"` 下一组**各自独立**的 `tristate`
（不是 `choice`，可以同时开多个语言）。所以要写的是：

```
CONFIG_LUCI_LANG_zh_Hans=y
```

打开它之后，实测自动带出三个中文包：
`luci-i18n-base-zh-cn`、`luci-i18n-firewall-zh-cn`、`luci-i18n-package-manager-zh-cn`。
注意符号名是 `zh_Hans`（下划线 + 大写 H），不是 `zh-cn`，也不是 `zh_CN`。

### 4.3 设备上的 apk 源（一个差点写错的结论）

`CONFIG_PER_FEED_REPO=y` 时，每个 feed 在设备上是 `/etc/apk/repositories.d/`
下一条独立的源，`CONFIG_FEED_*` 就是这组开关。

**实测结论，别想当然**：这组符号在 `tmp/.config-feeds.in` 里的定义是 `default y`。
把相关行从 `.config` 里**全部删掉**再 `make defconfig`，六个又都回到 `y`。
所以「不写它们会导致刷完机没有软件源」这个说法**不成立**。

那 seed 里为什么还显式写？因为**旧 `.config` 的残留值会盖过默认值**：我们这棵本地树里
它们就曾经是 `n`（早期某次 defconfig 留下的状态），不显式设成 `y` 就会一直保持 `n`。
CI 每轮都是全新的 `.config`，本来不受影响；显式写死是为了让本地和 CI 行为完全一致，
不出现「本地没源、CI 有源」这种悄悄分叉。

---

## 5. 时间与配额预期

| 场景 | 时长 |
|---|---|
| 冷跑（缓存空） | 1.5-3 小时 |
| 热跑（`dl` + ccache 命中） | 十几分钟到半小时 |
| `stage=dtb`（只验设备树） | 几分钟 |
| `stage=sync`（只验证补丁） | 不到一分钟 |

- 单个 job 硬上限 360 分钟，workflow 里设 `timeout-minutes: 350`，留时间给传产物和存缓存
- ccache 上限设成 `2G`；`dl` 大致 1-2 GB。两者一起在 Actions 缓存的 10 GB/仓库额度内
- 缓存按 `run_id` 做 key 滚动更新，命中靠 `restore-keys` 前缀匹配。**刻意没有把 dts 的哈希
  塞进 key** —— 那样「只改一行 dts」会整份丢缓存，反而更慢

---

## 6. 失败了怎么看

**首选：运行页面上的 annotations。** `ci/ci-build.sh` 里挂了 `trap ... ERR`，任何一步失败都会
打一条 `::error::` 出来，带行号和失败的那条命令。

之所以必须这么做：`GET /repos/{o}/{r}/actions/jobs/{id}/logs` 需要仓库 admin 权限，**公开仓库
也返回 403**（`Must have admin rights to Repository`）。公开可读的只有 check-run annotations，
而它只显示 `::error::` / `::warning::` 形式的行。不主动打 `::error::`，远程就只能看到一句
`Process completed with exit code 1.`，等于没有线索。

**次选：artifact 里的 `ags21-build.log`。** 完整编译日志（已滤掉 ANSI 色码），
包含 `fit_configs.py` 的完整输出。

---

## 7. 用到的 Action 版本

都按 2026-10 的实际 tag 核对过：

| 用的 | 最新 | 万一标签不存在就降级 |
|---|---|---|
| `actions/checkout@v7` | v7.0.1 | `@v4` |
| `actions/cache/restore@v6` / `save@v6` | v6.1.0 | `@v4` |
| `actions/upload-artifact@v7` | v7.0.2 | `@v4` |

`runs-on: ubuntu-24.04` —— 刻意选它而不是更新的版本，是为了和本地 WSL 的 Ubuntu 24.04 对齐。
环境一致，本地能编过，云上就没理由编不过。哪天 24.04 runner 退役，改版本号时记得同步本地环境。

---

## 8. 自检都查了什么

`ci/ci-build.sh` 在编译完之后会验：

1. `bin/targets/mediatek/filogic/` 里存在 `*aigo_ags21*.itb`
2. FIT 里**恰好只有 1 个**配置节点，且就是 `config-1`

第 2 条为什么是「数条数」而不是「取第一个值」—— 实测官方 RAX3000M 的 itb，
`fit_configs.py` 会给出**三条** `setenv` 建议（`config-1` 加两个 overlay）。如果只取第一条，
一个「base + overlay」的多配置镜像也会提取出 `config-1` 然后顺利通过，等于漏报。

我们的设计是单 DTS、无 overlay（原因见 `build/README.md` 第 3 节），所以条数必须是 1。
哪天有人误加了 `DEVICE_DTS_OVERLAY`，这里会立刻拦住并给出 `::error::`，
而不是等你刷上去发现起不来。

---

## 9. 什么时候还是该用本地

- **现在**：设备要靠串口救，急着出包，本地 20 核跑完最快
- **反复调 DTS 试错**：本地改完直接 `--stage=dtb` 几秒钟验证语法，比推一趟 CI 快得多
- **CI 出包了但想立刻验证**：本地和云共用同一套脚本，结论可直接互信
