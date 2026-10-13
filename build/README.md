# AGS21 自编 OpenWrt 25.12.5 固件 —— 编译材料包

这套材料的作用：把 AGS21 的**真实硬件差异**（1 WAN + 2 LAN、正确的 LED/按键、
1 GB 内存、正确机型名）编进官方 OpenWrt 25.12.5，出一份自己的
`sysupgrade.itb`。在此之前设备上跑的是官方 RAX3000M 通用镜像，能开机但
LED 全错、多出空网口、机型显示 CMCC。

---

## 0. 前置：先解封 WSL

本机装了 Ubuntu（`%LOCALAPPDATA%\Packages\CanonicalGroupLimited.Ubuntu_79rhkp1fndgsc`，
10.1 GB，已初始化），但 `wsl.exe` 命中 WorkBuddy 沙箱的**内置程序黑名单**
（`wsl.exe` / `wslconfig.exe` / `wmic.exe` / `sc.exe` / `reg.exe` / `schtasks.exe`），
在这个会话里跑不起来，而且提示不可绕过。

解除方式（二选一，都需要你操作）：

- **推荐**：安全中心 → 命令安全 → 程序黑名单 → 移除 `wsl.exe`
  （建议连 `wslconfig.exe`、`reg.exe` 一起移除，后者也常在排查时用到）
- 或者改 `~/.workbuddy/settings.json`，给 `sandbox` 加一个
  `"programBlacklist": []`（这个键只要是数组就完全覆盖内置默认值；写空数组等于
  整个黑名单失效）。改完可能要新开一个会话才生效。

解封后本机就有完整 Linux 环境了，`make` / `perl` / `git` / `python3` 都不用再绕。

> 提醒：这个名单拦的是「系统级工具」，解封 WSL 等于给会话一个完整的 Linux root
> 环境，能绕过 Windows 侧的文件保护。怎么取舍你自己定。

---

## 1. 怎么跑

在 WSL 里（**不要**在 `/mnt/c` 下编译）：

```bash
B=/mnt/c/Users/Administrator/WorkBuddy/2026-10-12-10-39-32/ags21_openwrt/build

# ① 拉源码 + 打补丁（几十秒，先确认补丁能干净应用）
bash $B/build-ags21.sh --stage=sync

# ② 只验设备树，DTS 语法/标签错误会在这步暴露（几秒出结果，不编内核）
bash $B/build-ags21.sh --stage=dtb

# ③ 完整编译，出固件（1-3 小时不等）
bash $B/build-ags21.sh
```

源码树默认落在 `~/openwrt-ags21`（`--workdir=` 可以改）。脚本**幂等**，
重复跑不会重复打补丁；锚点对不上会明确报错而不是乱改文件。

编译完脚本会自己打印产物路径、sha256，并调 `fit_configs.py` 告出
**U-Boot 的 bootconf 该设成什么**（见第 3 节，这一步很关键）。

### 编出来的固件里有什么

- **LuCI 网页界面**，走 HTTPS（`luci-ssl` = uhttpd + px5g 自签证书）。
  `luci` 是元包，会带出 `luci-base`、`luci-mod-admin-full`、`luci-mod-network`、
  `luci-mod-status`、`luci-mod-system`、`luci-app-firewall`、
  `luci-app-package-manager`、`luci-theme-bootstrap`
- **简体中文界面**（`luci-i18n-base-zh-cn` / `-firewall-` / `-package-manager-`）
- 设备上带 apk 软件源（`CONFIG_FEED_*`），刷完还能 `apk add` 装东西
- **首页多两块面板**：「CPU」（使用率，排在系统/内存之间）和「温度」
  （无线两个芯片 + SoC，紧跟在「无线」后面）—— 本仓库自带的包，见第 9 节
- **WireGuard**（`kmod-wireguard` + `wireguard-tools` + `luci-proto-wireguard`），
  LuCI 里「网络 → 接口 → 添加新接口 → 协议选 WireGuard」即可
- **ddns-go**（含 LuCI 界面）+ 上游包
- **homeproxy**（含 sing-box 1.12.x、kmod-nft-tproxy / -socket、kmod-tun），
  sing-box 已按 homeproxy 的需要打开 `with_acme` / `with_dhcp`（见第 10 节）
- **qrencode**（`/usr/bin/qrencode` 命令行二维码工具；LuCI 的 WireGuard 页面用的是
  纯前端 `luci-lib-uqr`，两者互不相干 —— 见第 10 节）

关于包来源，有一点必须说清楚：

| 包 | 来源 | 说明 |
|---|---|---|
| wireguard 全家桶 | **官方 feed** | 直接可用 |
| sing-box | **官方 feed**（`net/sing-box`，1.12.17） | homeproxy 只要它提供 `/usr/bin/sing-box`，但要**打开 ACME tag** |
| qrencode / libqrencode | **官方 feed**（`libs/qrencode`，4.1.1） | 命令行工具，不是 LuCI 二维码的依赖 |
| kmod-nft-tproxy / -socket、kmod-tun、firewall4 | **官方 feed / base** | 依赖齐全 |
| ddns-go、luci-app-ddns-go | **ImmortalWrt**，`vendor.sh` 按 commit 搬 | 官方 feed **没有** ddns-go（只有定位不同的 ddns-scripts） |
| luci-app-homeproxy | **ImmortalWrt**，`vendor.sh` 按 commit 搬 | 官方 feed **没有**；sing-box 本体官方有，所以只搬界面层 |

这些写在 `build-ags21.sh` 的 `REQUIRED_CONF` 清单里（缺哪行补哪行，幂等）。
云编译那边的对应文件是 `ci/config.seed`，两边内容要一致 —— 改一处记得改另一处。

> **中文那个有坑**：直接写 `CONFIG_PACKAGE_luci-i18n-base-zh-cn=y` 是**没用的**，
> `make defconfig` 会默默把它丢掉 —— 那个符号的默认值被 LuCI 生成成
> `default LUCI_LANG_zh_Hans||(ALL&&m)`。必须写 `CONFIG_LUCI_LANG_zh_Hans=y`，
> 它才会连带把三个中文包一起选上。实测过程见 `../ci/README.md` 第 4.2 节。
>
> **另一类同样的坑（2026-10-13 实测踩到）**：写了**根本不存在**的符号，
> defconfig 也会静默丢掉。举例：`luci-i18n-wireguard-zh-cn` —— 官方
> `luci-proto-wireguard` 目录下没有 `po/`，所以**不会生成任何 i18n 包**，
> 写这一行等于白写。WireGuard 界面的中文来自 `luci-base` 的 `base.po`
> （域名 `base`），`CONFIG_LUCI_LANG_zh_Hans=y` 已经把它带上了。
>
> 上面两种情况的表现完全一样：脚本打印「[补配置] …」，编译一路成功，
> 日志漂漂亮亮，只有刷完机发现少东西才知道。所以 `build-ags21.sh` 现在在
> `make defconfig` **之后**会逐行回读 `REQUIRED_CONF`，缺一行就 `die` 退出 ——
> 把这类问题挡在编译之前。

### 磁盘与时间

- 完整编译约需 **20-25 GB**（C: 现在剩 49 GB，够用；用 `--depth=1` 浅克隆省掉 ~1.3 GB 历史）
- 必须编在 Linux 原生文件系统里，`/mnt/c` 会有大小写敏感、符号链接、9p 性能三个坑
- 内存建议 ≥4 GB，`-j$(nproc)` 默认吃满核数

---

## 2. 补丁都改了什么（4 处补丁 + 1 处注入 + 2 个脚本 + 4 个包）

| 文件 | 改动 | 为什么 |
|---|---|---|
| `target/linux/mediatek/dts/mt7981b-aigo-ags21.dts` | **新增**（复制自 `../mt7981b-aigo-ags21.dts`） | 设备树，硬件数据全部来自实机提取 |
| `target/linux/mediatek/image/filogic.mk` | 追加 `Device/aigo_ags21`（见 `filogic.mk.add`） | 建一个自己的设备条目 |
| `.../filogic/base-files/etc/board.d/02_network` | 新增 `aigo,ags21)` 分支（幂等 + 可升级：旧版分支会被自动替换） | 网口定义：`lan1 lan2` + `wan=eth1`（实测定稿，见下） |
| `feeds/luci/modules/luci-mod-status/htdocs/.../status/include/10_system.js` | **注入**（锚点式，片段来自 `build/ags21-status-rows.js`；该文件由 feeds 提供，所以这一步在第 2.5 步装完 feeds 之后做） | 在「系统」面板里加「温度」「CPU 使用率」两行（第 9 节） |
| `.../filogic/base-files/lib/upgrade/platform.sh` | 3 条 case 列表各插一行 `aigo,ags21`\| | 让 sysupgrade 走 `fit_do_upgrade` |
| `.../filogic/base-files/etc/uci-defaults/99-ags21-port-rename` | **新增**（来自 `build/99-ags21-port-rename`） | 端口改名后迁移已存在配置里的 `br-lan` ports，否则升级后桥会桥不存在的接口 |
| `.../filogic/base-files/etc/board.d/04-ags21-wifi-defaults` | **新增**（来自 `build/04-ags21-wifi-defaults`） | 让「不保留配置」刷完后无线默认就是开的（第 11 节） |
| `package/luci-app-ags21-dashboard/` | **新增**（来自 `../packages/`） | 首页「CPU」「温度」两块面板（第 9 节） |
| `package/ddns-go/`、`package/luci-app-ddns-go/`、`package/luci-app-homeproxy/` | **新增**（`vendor.sh` 从 ImmortalWrt 按 commit 取，见第 10 节） | 官方 feed 里没有 |

上面 3 个 vendor 包**不是原样复制**：`vendor.sh` 会改两处，改不到就报错退出
（第 10 节有详细说明）。

两个刻意的「不做」：

1. **不重建 U-Boot**。官方 `mt7981_cmcc_rax3000m-emmc-ddr4` 的 BL2/fip 已经刷进设备，
   串口实测打印 `EMI: Detected DRAM size: 1024MB` —— 说明 DDR4 初始化完全兼容。
   重建 U-Boot 只会多花时间、多一份刷机风险。
2. **不用 `DEVICE_DTS_OVERLAY`**。官方 RAX3000M 用 base dts + emmc/nand 两个 overlay，
   是因为同一份镜像要同时支持两种启动介质。AGS21 只有 eMMC，所以 mmc0 / 分区 / nvmem
   全写进主 dts，FIT 里只有一个配置节点 `config-1`。

### 关于网口：已实测定稿（1 WAN + 2 LAN，名字对齐面板丝印）

- **WAN** = `eth1`（gmac1 + SoC 内置 GbE PHY，mdio 地址 0）。刻意**不给 gmac1 加 label**，
  保持 `eth1`，与官方 RAX3000M 一致（`ucidef_set_interfaces_lan_wan "lan1 lan2 lan3" eth1`）。
- **LAN1** = 面板丝印 **LAN1** = MT7531 **PHY1** → dts 的 `port@1`(label `lan1`)
- **LAN2** = 面板丝印 **LAN2** = MT7531 **PHY2** → dts 的 `port@2`(label `lan2`)
- `02_network` 同步写成 `ucidef_set_interfaces_lan_wan "lan1 lan2" eth1`

**为什么名字不再等于「PHY 号 + 1」**：上游对同芯片的 rax3000m 就是**按面板丝印**命名的 ——
它的 dts 里 `port@0/1/2` 偏偏写成 `lan3/lan2/lan1`，说明「label 要和丝印对上」才是约定，
「label = PHY + 1」不是。可追溯性放在 dts 注释里。

怎么定的（两条证据链）：

1. 第一版 dts 把 PHY0..PHY3 四个口全声明（原厂 dts 声明 4 个是 MTK 参考板
   `mediatek,mt7981-emmc-rfb` 的通用写法，不能据此推断接线），但那版 label 是「reg + 1」，
   所以 `lan2`=PHY1、`lan3`=PHY2。设备跑起来后轮询 `/sys/class/net` 下各口的 carrier、
   依次把网线插到两个 LAN 插座，**只有 lan2 / lan3 亮**，`lan1`/`lan4` 全程为 0：

```
mt7530-mdio mdio-bus:1f lan2 (uninitialized): PHY [mt7530-0:01]
mt7530-mdio mdio-bus:1f lan3 (uninitialized): PHY [mt7530-0:02]
```

   ⇒ 两个活口就是 MT7531 的 PHY1 / PHY2（DSA 用户口与交换机 PHY 一一对应）。

2. 再把网线插到**面板印着 LAN1 的那个口**：亮起来的是 `lan2` = **PHY1**
   （`mdio-bus:1f lan2: Link is Up - 10Mbps/Full → 1Gbps/Full`）。
   ⇒ 面板 LAN1/LAN2 与 PHY1/PHY2 **同序**，所以是「整体减一」的改名，不是对调。

顺带排除一个可能：mdio 总线上只有 `mt7530-0:00..03` 四个 PHY，**没有 AN8855 之类的
2.5G PHY 芯片**（官方 RAX3000M 新硬件版有），所以本机没有 2.5G 口。

> ⚠️ **改网口时三处必须一起改**：`mt7981b-aigo-ags21.dts` 的 label ↔ 本脚本里的
> `AIGO_BLOCK` ↔ `build/99-ags21-port-rename` 里的映射表。
> dts 里不存在的接口却被 `02_network` 桥进 br-lan，后果不是"少个口"，而是桥起不来、
> 设备直接失去网络，只能靠串口救。
>
> 为此 `build-ags21.sh` **每次编译都强制做一次一致性校验**（在补丁之后、编译之前）：
> 从 `02_network` 的 `aigo,ags21` 分支里取出 LAN 名单，和 dts 里所有 `label = "lanN"` 比对，
> 不一致就直接报错终止，不让它编出一个会把自己网络搞没的固件。实测输出：
>
> ```
> 02_network: LAN = lan1 lan2    WAN = eth1
> dts 里的 LAN label: lan1, lan2
> [OK] 02_network 与 dts 的网口名一致（LAN lan1 lan2 / WAN eth1）
> ```

#### 改名为什么必须带一个迁移脚本

`/etc/config/network` 只在「不存在或为空」时才由 board.d + `bin/config_generate` 生成
（`config_generate` 末尾就是 `if [ ! -s /etc/config/network ]`）。升级时配置是保留下来的，
所以 dts 改了端口名，`br-lan` 的 `ports` 还写着旧名字 —— 改名后 `lan3` 已经不存在，
桥会去桥一个不存在的接口，对应 LAN 口直接失效。

`build/99-ags21-port-rename` 装的 `/etc/uci-defaults/99-ags21-port-rename` 就是干这个的：
由 `/etc/init.d/boot` 在 S10boot 阶段执行（早于 S20network），返回 0 后被 `rm -f` 掉，
所以只在升级后首次开机跑一次。两个要点：

- **判据是 `lan3`**（只存在于旧命名空间）。没有这个判据就不幂等：`lan2→lan1` 与
  `lan3→lan2` 是一组，第二次执行会把新的 `lan2` 又改成 `lan1`，`'lan1 lan2'` 变成
  `'lan1 lan1'`；全新安装（board.d 直接生成 `lan1/lan2`）也会被误改。
  这个 bug 是拿配置副本干跑时发现的，别把判据删掉。
- **带 `:u*` 这类 VLAN 标志后缀的口名**（`config bridge-vlan` 的 `ports`）也一起改名，
  只换冒号前的部分。

---

## 3. ⚠️ 关键：bootconf 必须改（这是踩过的坑）

设备的 U-Boot 里有个环境变量决定用 FIT 的哪个配置节点：

```
bootconf=config-1#mt7981b-cmcc-rax3000m-emmc      ← 刷官方 RAX3000M U-Boot 带来的默认值
```

U-Boot 引导时执行的是 `bootm $loadaddr#$bootconf`，**配置节点名对不上就直接引导失败**。

我拿官方 sysupgrade.itb 验证过（`fit_configs.py`），它里面确实有：

```
configurations:
  config-1                          base (kernel+rootfs)
  mt7981b-cmcc-rax3000m-emmc        overlay
  mt7981b-cmcc-rax3000m-nand        overlay
```

正好对上。**而我们自编的镜像是单 DTS，只有 `config-1`，没有 overlay**，所以把我们的镜像
刷进去之后，必须在 U-Boot 里改成：

```
setenv bootconf config-1
saveenv
```

（或者干脆 `setenv bootconf` 删掉，让 U-Boot 用 FIT 里的 `default = "config-1"`。）

> OpenWrt 的 `sysupgrade` **不会**自动更新 bootconf（我查过 `platform.sh`，
> `fit_do_upgrade` 只管写 FIT 分区）。这一步必须手动做，否则 sysupgrade 重启后引导不了。
>
> `fit_configs.py` 会自动把该设的值算出来并打印，不用手抄。

---

## 4. 编完之后怎么用（和「明天上电」的关系）

时间线有两条路，不冲突：

**A. 明天先让设备起来（用官方通用镜像，材料已有）**
1. 抓 U-Boot 的 3 秒窗口（`finish_flash.py` / `finish_flash.bat`，或手敲：只发 ESC，别带回车）
2. 把 FIT 从 `recovery` 分区搬到 `production` 分区，回读校验
3. `reset` 引导 → 拿到一个能用的 OpenWrt（机型显示 CMCC 是正常的）
4. 插网线实测两个 LAN 口在哪两个 PHY 上、LED 行为

**B. 自编固件出来后（本材料包的产物）**
1. 从 A 步骤起来的系统里把自编的 `sysupgrade.itb` 传上去（scp 或网页上传）
2. `sysupgrade -n <file>` （`-n` 不保留配置，跨设备换固件建议不保留）
3. **重启前**先 `fw_setenv bootconf config-1`；若系统里没有 `fw_setenv`，
   就在下次上电的 U-Boot 窗口里手动 `setenv` + `saveenv`
4. 重启，确认 1 GB 内存、2 个 LAN、LED、机型名

**注意顺序**：别跳过 A 直接在 U-Boot 里写 B 的镜像 —— 那时候你还没有能跑的系统来传文件，
而 U-Boot 阶段传文件只能走 TFTP（需要网线 + PC 配 192.168.1.254 静态 IP，U-Boot 默认
`ipaddr=192.168.1.1` / `serverip=192.168.1.254`）。

---

## 5. 第一版刻意保守的地方

| 项 | 第一版取值 | 原厂取值 | 说明 |
|---|---|---|---|
| eMMC 频率 | `26000000` (26 MHz) | `0x632EA00` = **104 MHz** | 官方 RAX3000M 就用 26 MHz，先保证一定能起来；验证通过后改成 104 MHz 复测 |

写的是「先保证能起来」而不是「先跑得快」——因为设备现在是**靠串口救**的状态，
每多一次失败就多一轮拆机/断电。LED、按键极性、内存大小这些都已经是实测值，不是猜的。

---

## 6. 回退

- 全分区备份：`ags21_backup/`（10 个 `.img.gz` + `SHA256SUMS.txt` + `manifest.json`），
  含 `boot0`（BL2）、`fip`、`u-boot-env`、`factory`（WiFi 校准）、GPT 主表
- BROM 串口通道：`mtk_uartboot.exe` + `mt7981-ram-ddr4-bl2.bin`，当年实测跑通过 DDR4 初始化
- 串口：COM5 / 115200，CH341 的 BREAK 会被驱动降级成 `0x00` 字节，
  且 OpenWrt 内核没开 `CONFIG_MAGIC_SYSRQ_SERIAL`，所以**没法用 SysRq 强制重启，只能断电**

---

## 7. 文件清单

| 文件 | 说明 |
|---|---|
| `build-ags21.sh` | 主脚本：拉源码 / 装本地包 / vendor 第三方包 / 打补丁 / 编译 / 出产物 |
| `vendor.sh` | 把官方 feed 里没有的包（ddns-go / luci-app-homeproxy / luci-app-ddns-go）按固定 commit 从 ImmortalWrt 取进源码树，并打最小补丁（第 10 节） |
| `filogic.mk.add` | 要追加到 `filogic.mk` 的设备定义块 |
| `99-ags21-port-rename` | 端口改名后的一次性配置迁移脚本（装到 `/etc/uci-defaults/`） |
| `04-ags21-wifi-defaults` | board.d 无线默认值：让「不保留配置」刷完后无线默认是开的（装到 `/etc/board.d/`，第 11 节） |
| `ags21-status-rows.js` | 注入片段：往上游 `10_system.js` 里加「温度」「CPU 使用率」两行（第 9 节） |
| `fit_configs.py` | 解析 FIT，读出配置节点名并算出 bootconf |
| `fit_extract.py` | 从 FIT 里抠子镜像（主机没有 dumpimage），用来**从最终产物**验证 dtb/rootfs |
| `../mt7981b-aigo-ags21.dts` | 设备树（脚本会自动拷进源码树） |
| `../packages/` | 本仓库自带的包，目前只有 `luci-app-ags21-dashboard`（首页 CPU 使用率 / 温度两块面板，第 9 节） |
| `../ci/` | GitHub Actions 云编译（**补丁逻辑复用本目录脚本**，不另起一份）。用法与启用前提见 `../ci/README.md` |

已验证（2026-10-12，用真实上游 v25.12.5 文件离线跑）：

- 三处补丁在真实文件上能干净应用，重复执行不重复写入
- 补丁后 `02_network` / `platform.sh` 通过 `sh -n` 语法检查
- `fit_configs.py` 从官方 sysupgrade.itb 正确读出 `config-1` 与两个 overlay 名，
  与设备 U-Boot 的 `bootconf` 值吻合
- `build-ags21.sh` 通过 `bash -n`；`fit_configs.py` 通过 `py_compile`

**已实测（2026-10-12，在 WSL 的 Ubuntu 24.04 里跑通）**：`mt7981b.dtsi` 与 dt-bindings 都在内核源码树里，
所以 `--stage=dtb` 先跑一次 `target/linux/prepare`（约 2 分钟）拿到内核树，再用主机 `cpp` + `dtc`
直接编一遍设备树 —— **几秒出结果，完全不编内核**（dtb 编译本就只需要主机 cpp + dtc，
不需要交叉工具链）。实测产出 17,240 字节，只有 3 个 warning 且**全部来自内核自带的
`mt7981b.dtsi`**（第 691/519/399 行），与本 dts 无关。反编译回读逐项核对通过：
model / compatible / 1GB memory / LED(4,6,29) / 按键(0,1，WPS 为 ACTIVE_HIGH) /
switch(mt7531 reg=31、reset GPIO39 ACTIVE_HIGH、port0-3=lan、port6=cpu 2500base-x) /
eMMC(bus-width 8、26 MHz) / factory+production 分区 / rootdisk。

> 踩坑记录：OpenWrt 25.12 **已经没有 `tools/dtc` 这个包**（dtc 由主机提供，Ubuntu 上就是
> `/usr/bin/dtc` 1.7.0），所以旧写法 `make tools/dtc/compile` 会报
> `No rule to make target 'tools/dtc/compile'`。脚本已改成直接调用主机 dtc。

> 踩坑记录（编译顺序，2026-10-12）：**别手搓 `toolchain/install` + `target/install`
> + `make image` 三步**。`target/install` 会去生成 `root.squashfs`，而
> `build_dir/target-*/root-mediatek` 这个目录是 **`package/install` 填出来的**；
> 少了 package 那两步，就会在 `root.squashfs` 处报
> `Cannot stat source directory .../root-mediatek` 而失败 —— 第一次完整编译就是这么
> 挂了 24 分钟，日志里只有一句 `ERROR: target/linux failed to build.`。
> 顶层 `Makefile` 里的 `world` 才是权威顺序：
> `prepare → target/compile → package/compile → package/install → target/install
> → package/index → checksum`。**镜像生成属于 `target/install`**，不用再单独 `make image`。
> 脚本已改成 `make -j$(nproc) world`。

---

## 8. 后续升级怎么刷、配置为什么能保住（2026-10-13 实测）

设备跑起自编 OpenWrt 之后，升级就不用再走串口 YMODEM 了，直接用官方 sysupgrade 通道：

```sh
sysupgrade -T /tmp/fw.itb     # 预检：只校验镜像签名/机型，不刷（实测输出 Signature check OK）
sysupgrade    /tmp/fw.itb     # 刷；默认保留配置（SAVE_CONFIG=1 就是默认值）
```

- 上传用 `owrt_put.py`（本机没 sshpass/plink，paramiko 走密码 SSH）。**这个镜像是 dropbear，
  没有 sftp-server**，脚本会自动退到 `cat > 远端` 通道；实测 11.5 MB 走 WiFi 只用 2.7 秒。
- Windows 侧调它时 `/tmp/...` 参数要配 `MSYS_NO_PATHCONV=1`，否则 Git Bash 会把远端路径
  改写成 `C:/Users/.../AppData/Local/Temp/...`。
- `sysupgrade` **自己并不写盘**：它 `install_bin /sbin/upgraded` 之后把活交给 `upgraded`
  守护进程（`ubus call system sysupgrade`）。所以**在 SSH 里前台跑是安全的** ——
  那句 `Commencing upgrade. Closing all shell sessions.` 会切断你的会话（ubus 客户端报
  `Connection failed` + exit 246 都属正常），刷写继续在守护进程里跑完。实测从提交到设备
  重新可 ping 约 1 分半。

### 配置为什么能保留（机制）

镜像文件尾部有 **176,392 字节的 fwtool 元数据**（首 4 字节 `de ad c0 de` + 0xff 填充）：

```
文件总长            12,058,888
FIT 数据末端        11,882,496   ← 第 11,882,496 字节处就是 de ad c0 de
fwtool 元数据长度      176,392
```

`emmc_upgrade_fit` 是 `get_image | fwtool -i /dev/null -T - | dd`，**fwtool 会把这段元数据剥掉**，
所以实际只写 11,882,496 字节。而 overlay 分区 `fitrw` 在 production 里的起点**正好也是
11,882,496**（= 分区 917504 块 − 23208 块）。两者恰好对齐 ⇒ FIT 写入**完全没碰到 overlay**，
root 口令 / 无线 / 网桥改动原样保留。

升级后立刻取的证据：

```
/overlay 数据只有 64.5K，但 df 显示 fitrw 已用 56.9M（升级前 56.8M）   ← 同一份 f2fs，没重建
/overlay/upper/etc 只有 20 个条目（不是整棵 /etc 的拷贝）               ← 不是"格式化后恢复"
/etc/config/network 的 mtime 仍是升级前那次 uci commit 的时间
```

另外，运行中的固化 FIT 被读回来比对过 sha256，与 `out/` 里的文件**逐字节一致**
（`dd if=/dev/mmcblk0p5 bs=512 count=23208 | sha256sum` ↔ 本地文件前 11,882,496 字节）。

### 配置保住了，但**端口改名不会自动生效** —— 所以要有迁移脚本

保留配置是好事，但 `/etc/config/network` 有个前提：它只在**不存在或为空**时才由
board.d + `bin/config_generate` 生成（`config_generate` 末尾就是
`if [ ! -s /etc/config/network ]`）。也就是说，**dts 改了端口名，已经存在的配置不会跟着变**。

2026-10-13 把两个 LAN 口从 `lan2/lan3` 改名为 `lan1/lan2` 时就撞上这个：升级后
`br-lan` 的 `ports` 还写着 `'lan2' 'lan3'`，而那时 `lan3` 已经不存在 → 桥会去桥一个不存在的
接口，那个 LAN 口直接失效（还不一定报错，很难查）。

`build/99-ags21-port-rename` 装的 `/etc/uci-defaults/99-ags21-port-rename` 负责迁移：
`/etc/init.d/boot` 在 S10boot 阶段跑 `/etc/uci-defaults/*`（**早于 S20network 起网**），
返回 0 就被 `rm -f` 掉，所以升级后只会跑一次。实测本次升级后：

```
uci show network → network.@device[0].ports='lan1' 'lan2'     ← 已迁移
/sys/class/net   → br-lan eth0 eth1 lan1 lan2 lo phy0-ap0 phy1-ap0
桥成员            → lan1, lan2
ls /etc/uci-defaults | grep 99-ags21-port-rename → 0 条        ← 已被消费（白化删除）
dmesg            → lan1 (uninitialized): PHY [mt7530-0:01]
                   lan2 (uninitialized): PHY [mt7530-0:02]
```

> **这个脚本必须先在设备上干跑过再打包**。本次就是靠干跑抓到一个致命 bug：
> 第一版没有「旧命名空间」判据，第二次执行会把新的 `lan2` 又改成 `lan1`，
> `'lan1 lan2'` 变成 `'lan1 lan1'`，而且**全新安装**（board.d 直接生成 `lan1/lan2`）
> 也会被它改坏。修法是只在名单里出现 `lan3`（旧命名空间独有）时才迁移。
> 干跑方法：把 `/etc/config/network` 复制到 `/tmp/mig/`，用
> `PATH=/tmp/bin:$PATH` 前置一个 `exec /sbin/uci -c /tmp/mig "$@"` 的包装脚本，
> 再跑真实脚本本体 —— 零风险，还顺手验证了幂等。

> ⚠️ **推论**：配置能保住的前提是「新 FIT 数据末端 ≤ overlay 起点」。以后若镜像变大
> （内核长大、加包）就会压进 f2fs 开头，overlay 会被毁 —— 那时靠的是
> `platform_copy_config → emmc_copy_config` 把备份 tarball 追加在 FIT 之后、开机时由
> `libfstools` 取回。这一次那条路**没有触发**（f2fs 超级块完好可证），所以
> **升级前自己留一份更稳**：`sysupgrade -b /tmp/backup-$(date +%F).tar.gz`。

---

## 9. 首页的「温度」与「CPU 使用率」两行（注入进「系统」面板）

### 目标排版

```
状态
  系统
    主机名            OpenWrt
    型号              AIGO AGS21
    架构              …
    温度              CPU: 58.4°C, WiFi: 44.0°C 44.0°C      ← 新增
    目标平台          mediatek/filogic
    固件版本          …
    内核版本          …
    本地时间          …
    运行时间          …
    平均负载          0.07, 0.11, 0.09
    CPU 使用率（%）    28%                                   ← 新增
```

### 两条路，最后走的是第二条

LuCI 总览页有**两种**扩展方式，能力并不一样：

| 方式 | 能做什么 | 能不能在「系统」块**内部**加行 |
|---|---|---|
| 往 include 目录丢 `NN_xxx.js` | 加一整块**独立面板**（自带标题） | ✗ 面板之间没法互相插行 |
| 改 `10_system.js` 的 `fields` 数组 | 在系统块内部加行 | ✓ |

最初做的是第一种（`15_cpu_usage.js` + `61_wifi_temp.js`，温度挂在「无线」面板后面）。
但用户给的参照物是 ImmortalWrt 首页，那两行是**系统块内部的行**，所以改成第二种，
那两个文件已删除。

### 改法：锚点式注入，不是覆盖文件

`build/ags21-status-rows.js` 是注入用的 JS 片段（在仓库里可读、可 review），
`build-ags21.sh` 第 4.4 步把它按锚点插进上游 feed 的这个文件：

```
feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js
```

五处锚点，每处都要求**恰好命中 1 次**，对不上就 `die`：

1. 采集函数插在 `callSystemInfo` 声明之后
2. `load()` 的 `Promise.all` 里多取两样，插在 `callGetUnixtime` 之后、
   `uci.load('system')` 之前 ⇒ 上游原有 5 个元素是 `board(0) info(1)
   luciVersion(2) unixtime(3) uci.load(4)`，插入后 `ags21Temps=data[4]`、
   `ags21CPUUsage=data[5]`，`uci.load` 被顶到 `data[6]`。
   ⚠️ **不是 `data[5]`/`data[6]`** —— 这里差一位的后果非常隐蔽：「温度」行会显示
   CPU 使用率、「CPU 使用率」行显示一个 uci 对象，但**编译不报错、加载也不报错**。
   2026-10-13 真踩过（第一版就是错的），现已在 `build-ags21.sh` 加了**索引一致性
   硬校验**：把 `load()` 的实参真的拆出来数一遍，再和 `render()` 里的
   `data[N]` 对比，不一致就直接 `SystemExit`。
3. `render()` 里把这两个返回值接出来
4. 温度行插在 `_('Architecture')` 之后
5. CPU 使用率行追加在 `fields` 末尾

**为什么原位打补丁，而不是自己包再装一个同路径文件**：同名文件分属两个包时，
谁覆盖谁取决于安装顺序，不可控；而且上游一升级，我们的副本会**静默**过期
（首页悄悄少一行，没人会发现）。原位锚点式补丁正相反 —— 上游文本一变立刻报错。

**副作用（必须配套做）**：luci 是「无源码」包（`Package/install` 直接 copy htdocs），
OpenWrt 的 `.built` 戳**不会**因为 htdocs 变了而失效。不处理的话编译照样成功、
镜像里却还是旧文件。所以第 6 步编译前会显式清掉 `luci-mod-status` 的构建戳与旧包。

### 取值口径（对着 ImmortalWrt 的 `/sbin/tempinfo` 抄的）

ImmortalWrt 那两行是**三处配合**的产物：`package/emortal/autocore`（提供
`/sbin/tempinfo`、`/sbin/cpuinfo`）+ `luci-base` 里的 ucode rpcd 插件
（暴露 `luci.getTempInfo` / `luci.getCPUUsage`）+ `10_system.js` 里两个
`rpc.declare`。我们用的是**上游 luci**，没有那个 ucode 插件。

而这两样数据的来源本来就在本地：`/proc/stat` 与 `/sys/class/hwmon`，前端
`fs.read / fs.list`（走 rpcd 的 `file` 对象）就能拿到，本包也有对应 ACL。
所以采集放在前端做：少两处改动、少一个 shell 脚本、少一个每 5 秒 fork 一次的
`top -n1`，**输出格式仍与 tempinfo 逐字一致**：

| 组 | ImmortalWrt 的取法 | 我们的取法 |
|---|---|---|
| CPU | `/sys/class/thermal/thermal_zone0/temp` | hwmon 里 `name=cpu_thermal` 的那个（同一颗传感器） |
| WiFi | `/sys/class/ieee80211/` 下每个 phyN 的 `hwmonM/temp1_input` | 枚举 `/sys/class/hwmon/hwmonN`，按 `name` 归类 |

拼成 `CPU: 58.4°C, WiFi: 44.0°C 44.0°C`（每位保留 1 位小数，组内用空格连，
两组用 `, ` 连）；CPU 使用率是 `28%`。

AGS21 上有**三路互不相干**的温度传感器（串口实测）：

| hwmon | name | 实测值 | 是什么 |
|---|---|---|---|
| hwmon0 | `cpu_thermal` | 54.5–55.0 °C | SoC |
| hwmon1 | `mt7915_phy0` | 44.0 °C | 无线 2.4 GHz 芯片 |
| hwmon2 | `mt7915_phy1` | 44.0 °C | 无线 5 GHz 芯片 |

MT76 驱动把**两个无线芯片的结温单独注册成了 hwmon**，而 `/sys/class/thermal`
里**只有 SoC 一路** ⇒ 温度只能走 hwmon。用 hwmon 还有个附带好处：不怕编号变化，
以后驱动多注册了别的传感器会自动出现，不用改代码。

- **CPU 使用率**：两次 `/proc/stat` 采样求差分（`100 * (1 - Δidle/Δtotal)`，空闲按
  `idle + iowait` 算，与 `top` 的口径一致）。比读 loadavg 准确 —— loadavg 是
  1/5/15 分钟平均，开盘瞬间完全反映不出突发占用。
  首次加载时没有上一次采样，脚本会**等 300ms 再读一次**，所以一打开首页就有数字，
  不用干等下一轮轮询（默认 5 秒一轮，`index.js: poll_status`；模块级变量存上一次采样）。

顺带说明：**这台机器没有 cpufreq**（`/sys/devices/system/cpu/cpufreq/` 是空的，
dts 里也没有 `operating-points-v2`），所以不显示频率。

### 五个坑

1. **文案硬编码中文，没走 `_()`**。LuCI 的 `.lmo` 是**按页面所属域名**加载的：
   状态总览页属于 `luci-mod-status`，而 `luci-mod-status` 连 `po/` 目录都没有 ——
   它的字符串全在 `luci-base` 的 `base.po` 里（域名 `base`）。
   ImmortalWrt 那两行的 msgid 是 `Temperature` / `CPU usage (%)`，但**上游**
   `base.po` 里这两个都没有（实测 grep 为空），照抄会显示英文；
   我们也没法把自己的 `.lmo` 塞进 `base` 域名，那会和 `luci-base` 抢同一个
   `/usr/lib/lua/luci/i18n/base.zh-cn.lmo`。这版固件本来就只有中文界面，
   直接写中文最省事。将来要英文，把片段里的字符串换成 `_('...')` 并给 `base.po`
   补两条 msgstr（都能做，只是现在没必要）。

2. **ACL 用一条通配就够**。`/sys/class/hwmon/hwmonN` 是**软链接**，解析后的真实
   路径已经完全换了个地方（串口实测）：

   | 字面路径 | realpath |
   |---|---|
   | `/sys/class/hwmon/hwmon0` | `/sys/devices/virtual/thermal/thermal_zone0/hwmon0` |
   | `/sys/class/hwmon/hwmon1` | `/sys/devices/platform/soc/18000000.wifi/ieee80211/phy0/hwmon1` |
   | `/sys/class/hwmon/hwmon2` | `/sys/devices/platform/soc/18000000.wifi/ieee80211/phy1/hwmon2` |

   **不用逐条枚举**：rpcd 的 ACL 匹配就是
   `fnmatch(acl->object, obj, FNM_NOESCAPE)`（`session.c:146`），**没有 `FNM_PATHNAME`**
   ⇒ `*` 可以跨 `/`，一条 `/sys/class/hwmon/*` 就覆盖了 `hwmonN/temp1_input` 这种。
   这点用 C 写了个对照实验验证，pattern 不变、只换 flags：

   ```
   FNM_NOESCAPE（rpcd 实际用的）：
     [匹配]   /sys/class/hwmon/*              → /sys/class/hwmon/hwmon1/temp1_input
     [不匹配] /sys/class/hwmon/*              → /proc/stat          （反例，符合预期）
   FNM_PATHNAME（假想的另一种实现）：
     [不匹配] 上面全部                ← 证明这个实验有区分度，不是「什么都能匹配」
   ```

   所以本版 ACL 就 3 条：`/proc/stat` read、`/sys/class/hwmon` list、
   `/sys/class/hwmon/*` list+read。
   2026-10-13 又用**真实 rpcd 会话**在设备上端到端验过（静态推断之外的第二重证据）：

   ```sh
   SID=$(ubus call session login '{"username":"root","password":""}' \
         | jsonfilter -e '@.ubus_rpc_session')
   ubus call file list "{\"path\":\"/sys/class/hwmon\",\"ubus_rpc_session\":\"$SID\"}"
   #   → hwmon0 hwmon1 hwmon2
   ubus call file read "{\"path\":\"/sys/class/hwmon/hwmon0/temp1_input\",\"ubus_rpc_session\":\"$SID\"}"
   #   → { "data": "50083\n" }
   ```

   注意 `ubus` CLI **没有**「指定会话」的开关（`-S` 是 simplified output），
   会话要靠**报文里的 `ubus_rpc_session` 字段**传给 rpcd。

3. **注入的代码里千万别出现「星号 + 斜杠」**。它整体嵌在 `/* … */` 块注释里，
   写通配路径时手滑就会**提前结束注释**、整段变成语法错误。本次真踩过：
   注释里写 `phy*/hwmon*/temp1_input`，`node --check` 立刻报
   `SyntaxError: Invalid regular expression: missing /`。
   所以注释里一律用 `phyN` / `hwmonM` 这种占位写法。
   （改完注入片段一定要跑一次 `node --check`，见第 7 节的自检清单。）

4. **系统块的行只有 name/value 两列**，所以取值读不到时就渲染成 `?`
   （没有「读不到 /proc/stat」那种长文案的余地）。`10_system.js` 全程
   `L.resolveDefault`，**不会 reject** —— 一旦 reject，整块「系统」面板都会消失。

5. **构建会把 JS 压缩，注释全被剥掉** —— 所以**别拿源码里那个
   `AGS21 注入段` 注释当设备端判据**。源码注入后是 8332 B，产物里只有
   4537 B（`root.squashfs` 抽出实测），`grep -c 'AGS21 注入段'` 在设备上
   **永远是 0**，照着查会误判成"没注入"。设备端正确判据是数标识符：

   | 查什么 | 期望次数 |
   |---|---|
   | `ags21Temps` / `ags21CPUUsage` | 各 **2**（1 定义 + 1 调用） |
   | `ags21_temp` / `ags21_cpu` / `ags21IsWireless` | 各 **2** |
   | `温度` / `CPU 使用率（%）` | 各 **1** |
   | `AGS21 注入段` | **0**（注释已没，别用） |

   而 `build-ags21.sh` 里那条「`AGS21 注入段` ×2」自检查的是**源码**，
   在压缩之前，不受影响，保留。

### 为什么这个包现在只装一个 ACL

`luci-app-ags21-dashboard` 以前装两个 JS 面板，现在**只装一个 ACL json**
（包名保留，省得动 `.config` 里的 `CONFIG_PACKAGE_...=y`）。JS 走注入，不进包。
不用 `luci.mk` 的理由同前：不需要 i18n / 压缩 / 版本推导那一套（文案不翻译，
见第 1 点），普通 OpenWrt 包写法更简单，也没有「包不在 git 仓库里 →
`PKG_SRC_VERSION` 退化成 `0`」的坑（那个坑 vendor 进来的包会撞上，见第 10 节）。
`DEPENDS:=+luci-base +luci-mod-status` —— 后者是因为 ACL 授权的东西是它的面板在用的。

---

## 10. 第三方包：ddns-go 与 homeproxy（`vendor.sh`）

### 为什么必须 vendor

| 包 | 官方 `openwrt/packages` | 官方 `openwrt/luci` | 结论 |
|---|---|---|---|
| `wireguard-tools` / `kmod-wireguard` | ✅ 有 | ✅ `luci-proto-wireguard` | 直接用官方 |
| `sing-box` | ✅ 有（`net/sing-box`，1.12.17） | — | 直接用官方，但要**打开 ACME tag**（见下） |
| `ddns-go` | ❌ 只有 `ddns-scripts`（定位完全不同） | — | 必须搬 |
| `luci-app-homeproxy` | — | ❌ 没有 | 必须搬 |
| `luci-app-ddns-go` | — | ❌ 没有 | 必须搬 |

`ddns-go` / `luci-app-homeproxy` / `luci-app-ddns-go` 都是 **ImmortalWrt** 独有的。
`sing-box` 本体官方 feed 就有，所以 homeproxy 只需要搬 LuCI 界面那一层。

### 怎么搬（钉死版本）

`vendor.sh` 按**固定 commit** 从 ImmortalWrt 浅取（GitHub 支持
`git fetch --depth 1 origin <SHA>`，实测可用），**只复制需要的子目录**，
不引入 ImmortalWrt 的整个 feed（那会和官方 luci / packages 里的同名包打架）。
缓存放在 `$WORKDIR/.vendor/`，同一个 commit 不重复下载。

```bash
IV_LUCI_URL="https://github.com/immortalwrt/luci.git"
IV_LUCI_COMMIT="5fc1fac5684cac6eee2c7fbff78c65b867980dd8"   # master @ 2026.10.02
IV_LUCI_VERSION="2026.10.02"
IV_PKGS_URL="https://github.com/immortalwrt/packages.git"
IV_PKGS_COMMIT="25ad600a90980bed1ee76a212f9a5e42b499bb62"  # master @ 2026.10.10
```

升级 = 改这两个 `*_COMMIT`（顺带改 `IV_LUCI_VERSION`）。

### 复制过去之后必须打的两处补丁

上游的包是「住在 feed 里」的，两个假设在 `$WORKDIR/package/` 下不成立：

1. **`include` 用了相对路径**（从 `feeds/<feed>/<子目录>/` 往上数两级的写法）：
   - `packages/net/ddns-go/Makefile`：`include ../../lang/golang/golang-package.mk`
   - `applications/luci-app-*/Makefile`：`include ../../luci.mk`
   搬到 `package/` 下就必须改成绝对指向 feed 里的那个 mk。

2. **版本号**。`luci.mk` 里 `VERSION:=$(if $(PKG_VERSION),...,$(PKG_SRC_VERSION))`，
   而 `PKG_SRC_VERSION` 是用 `git log -1` 在**包目录所在的 git 仓库**里算出来的。
   vendor 进来的目录在 OpenWrt 主仓里是 untracked、又不在 luci feed 的 git 里，
   `findrev` 会返回 `"0"`，版本就退化成 `0`。所以显式钉成上面的日期。

`vendor.sh` 改完会**断言**：改不到锚点、或还有残留的相对 `include` 就直接报错退出，
不会把半成品放过去。实测输出：

```
  ddns-go                golang             已打补丁
  luci-app-ddns-go       luci               已打补丁
  luci-app-homeproxy     luci               已打补丁
```

### 实测确认过的运行期依赖（省得再查一遍）

- homeproxy 的 `root/etc/init.d/homeproxy` 只调用 `/usr/bin/sing-box`，
  **不需要 chinadns-ng**（官方 feed 里也没有）—— 它的 DNS 分流是用 sing-box 自己
  监听 `127.0.0.1`，配合 dnsmasq 的 `nftset=` 把域名塞进 nft 集合。
- 官方 `sing-box` 定义了 `USERID:=sing-box=5566`，homeproxy 的
  `procd_add_jail ... procd_set_param user sing-box` 才成立。
- **`dnsmasq` 2.93 自带 `nftset`**（设备上 `dnsmasq --version` 里有），
  所以**不用**换成 `dnsmasq-full`。
- `rpcd-mod-file` / `rpcd-mod-ucode` / `ucode-mod-digest` / `firewall4`
  在默认镜像里就已经装了。
- **`ucode-mod-math` 是 homeproxy 上游漏声明的依赖**（本轮才发现）：
  `etc/homeproxy/scripts/generate_client.uc:11` 写着
  `import { isnan } from 'math'`（第 177 行真的在调用它），
  但上游 `LUCI_DEPENDS` 只列了 `+ucode-mod-digest`，**没写 `+ucode-mod-math`**。
  它能跑只是因为 `luci-base` 顺带带上了（`luci-base` 自己的
  `ucode/dispatcher.uc:8` 也 `import { rand } from 'math'`，且它的 `DEPENDS`
  里确有 `+ucode-mod-math`）。
  **我们已在 `REQUIRED_CONF` / `ci/config.seed` 里显式钉住这一行** ——
  不把「上游碰巧带上」当保证。真缺了的症状：启用 homeproxy 客户端时报
  `Unable to resolve module 'math'`，客户端配置生成直接失败。
- 顺带做过一次全镜像排查：**104 条 ucode 模块引用全部可解析**。
  唯一解析不到的 `lua` 是 `luci/dispatcher.uc:70` 里被 `try/catch` 守卫的
  **可选**兼容层（只有 Lua 版 LuCI 插件才需要，我们一个都没有）。
- homeproxy 默认 **disabled**（`/etc/config/homeproxy` 的 `enabled '0'`），
  不手动启用它不会碰 dnsmasq 配置。

### sing-box 的编译特性：ACME 必须打开（否则 homeproxy 服务端会挂）

这是「版本与兼容」里最容易漏的一条。

官方 feed 的 `sing-box/config` 把一批特性做成**默认关闭**的可选 tag，
而 ImmortalWrt 自家那份 sing-box 的 `GO_PKG_TAGS` 是**写死**的：

| tag | 官方 feed（默认） | ImmortalWrt | 结论 |
|---|---|---|---|
| `with_clash_api` / `with_gvisor` / `with_quic` / `with_tailscale` / `with_utls` / `with_wireguard` | ✅ 默认 y | ✅ | 一致 |
| **`with_acme`** | ❌ 默认 n | ✅ | **必须打开** |
| **`with_dhcp`** | ❌ 默认 n | ✅ | 建议打开（对齐） |

为什么 ACME 是硬需求：homeproxy 的
`root/etc/homeproxy/scripts/generate_server.uc` 在服务端配置里会生成
`acme: { domain, email, provider, … }`（自动申请 TLS 证书）。sing-box 若**没有**
编 `with_acme`，读到这个字段会直接启动失败 —— 表现为「启用 homeproxy 服务端就起不来」，
而日志不会明说原因。

打开方式（已在 `REQUIRED_CONF` 与 `ci/config.seed` 里）：

```
CONFIG_SINGBOX_WITH_ACME=y
CONFIG_SINGBOX_WITH_DHCP=y
```

官方包的 tag 是 config 驱动的（`Makefile` 第 122–134 行 `GO_PKG_TAGS := $(if $(CONFIG_SINGBOX_WITH_ACME),with_acme) …`），
所以只要打开这两个开关，tags 就和 ImmortalWrt 完全对齐。

**版本号本身不用动**：官方 1.12.17 vs ImmortalWrt 1.12.25，同属 1.12.x，
配置格式兼容；而且 homeproxy 源码里那句注释
`/* leave for sing-box 1.13.0 */`（`generate_client.uc`）恰好说明**它当前就是面向
1.12.x 写的**，1.13.0 的新 `sniff` 动作还没启用。等 ImmortalWrt 的主线升到 1.13 并
重新 vendor 了 homeproxy，才需要跟着动 sing-box。

### qrencode：为什么装了它，WireGuard 界面却不靠它

`qrencode`（官方 `feeds/packages/libs/qrencode`，4.1.1）提供两个包：

- `libqrencode` —— C 库
- `qrencode` —— 命令行工具 `/usr/bin/qrencode`（`DEPENDS:=+libqrencode`）

**WireGuard 页面的二维码跟它没关系**：官方 `luci-proto-wireguard` 的依赖是
`+luci-lib-uqr`，二维码在前端用 µQR（纯 JS，生成 SVG）画出来，**不调用任何后端**。
真正 `fs.exec('/usr/bin/qrencode', …)` 的只有 `luci-app-fwknopd`（我们没装）。

这里装 qrencode 是为了**命令行/脚本**里能出二维码，例如：

```sh
qrencode -t ANSIUTF8 'WIFI:T:WPA;S:MySSID;P:mypass;;'   # 终端里直接打出可扫的码
```

配置里开的 `CONFIG_QRENCODE_PNG=y` 让 `-o x.png` 能输出 PNG（会连带拉上 `libpng`）。
不要 PNG 就删掉那一行，`qrencode` 仍能输出 `ANSI / ANSIUTF8 / UTF8 / SVG`。

---

## 11. 让固件「默认无线就是开的」（`board.d/04-ags21-wifi-defaults`）

### 问题

「不保留配置」刷完机后，无线是**关着的**：`/etc/config/wireless` 里两个
`wifi-iface` 都带 `disabled '1'`、SSID 回到 `OpenWrt`、无加密，必须进 LuCI 手动开。
（2026-10-13 设备实测，不是推测。）

### 根因：`disabled` 是**算出来的**，不是写死的

OpenWrt 25.x 的默认无线配置由 `/lib/wifi/mac80211.uc` 在开机时**生成**。它的结尾是：

```
set ${si}.ssid='${defaults?.ssid || "OpenWrt"}'
set ${si}.encryption='${defaults?.encryption || encryption}'
set ${si}.disabled='${defaults ? 0 : 1}'          ← 这一句决定开还是关
```

而 `defaults` 取自 `/etc/board.json` 的 `wlan.defaults`：

```
defaults = board.wlan.defaults.ssids?.[band_name]?.ssid
           ? board.wlan.defaults.ssids?.[band_name]
           : board.wlan.defaults.ssids?.all;
country  = board.wlan.defaults.country;
if (!country && band_name != '2g')
        defaults = null;                          ← 5G 没国家码直接作废
```

AGS21 的 `board.json` 里只有 `wlan.phy0/phy1` 的**硬件能力**（band / channel / htmode），
没有任何 `wlan.defaults` ⇒ `defaults` 为空 ⇒ 生成的接口 `disabled '1'`。

### 为什么补在 `board.d`，而不是 `/etc/uci-defaults`

`board.json` 是**因**，`/etc/config/wireless` 是**果**：

```
/bin/config_generate
  └─ /bin/board_detect          → (. /etc/board.d/*)  产出 /etc/board.json
     … 生成 /etc/config/network 等
wifi 服务起来 → mac80211.uc 读 board.json → 生成 /etc/config/wireless
```

`/etc/uci-defaults/*` 跑在更早的 `/etc/init.d/boot` 里，那时 `/etc/config/wireless`
还不存在，`uci set` 写在空气上 —— 顺序不可靠。所以必须在 board.d 这一层补。

（`/bin/board_detect` 用的是 `(. "$a")` **source**，只检查 `[ -s "$a" ]` 非空，
严格说不要求执行位；脚本照旧 `install -m 0755`，与上游 `04_defaults` 等保持一致。）

### 5G 那行 `country` 不是装饰

`mac80211.uc` 里 `if (!country && band_name != '2g') defaults = null;` ——
**没有国家码，5G 的 defaults 会被丢掉，5G 仍然是 `disabled '1'`**。
所以 `ucidef_set_country CN` 是功能必需。顺带让驱动加载正确的 regulatory 域。

### 实际写入的值（= OpenWrt 原样默认 + 一个必需的国家码）

| 项 | 值 | 说明 |
|---|---|---|
| SSID | `OpenWrt` | 上游默认值 |
| 加密 | `none` | 上游默认值，**无密码** |
| 国家码 | `CN` | 唯一多出来的一项，见上：5G 没它就不启用 |

用户 2026-10-13 明确要求「无线打开就行，用 OpenWrt 的默认设置、无密码」，
所以不写 key、不给 `psk2`。想改成加密网络就把 `encryption` / `key` 补进
`build/04-ags21-wifi-defaults` 的那两行（配套要先改掉 `build-ags21.sh` 里
那条「不得给 encryption/key」的断言 —— 它是故意挡手滑的）。

### 编译期自检（重要）

「默认开无线」失败时**编译期完全看不出来** —— 镜像照样编过，刷进去才发现无线是关的。
所以 `build-ags21.sh` 在补丁后强制校验脚本存在、非空、有 `aigo,ags21` 分支、
2g/5g 都给了 ssid、设了 `country`，并且**没有**给 `encryption`/`key`。通过会打印：

```
[OK] 无线默认值：bands=2g,5g，country 已设，无密码（上游默认 SSID）
```

### 只对 aigo,ags21 生效

本文件装在 `target/linux/mediatek/filogic/base-files/` 下，会被**所有** filogic 设备共用，
所以用 `case "$(board_name)" in aigo,ags21)` 包起来，不会污染 cmcc,rax3000m 等机型。

### 刷完怎么确认

```sh
uci show wireless | grep -E 'ssid|encryption|disabled'
# 期望：default_radio0/1 的 ssid = OpenWrt、encryption = none、disabled = 0，且没有 key
iwinfo
# 期望两行 ESSID: "OpenWrt" + Encryption: none
```

注意这个文件只在 **`/etc/board.json` 不存在时**才会被 board_detect 执行，
即只影响全新安装 / 不保留配置的重置；**保留配置升级时老配置原样保留**，不受影响。

