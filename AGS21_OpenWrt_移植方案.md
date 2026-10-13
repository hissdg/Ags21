# 爱国者 AIGO AGS21 → 官方 OpenWrt 移植方案

> 依据：设备实机信息采集（root shell）+ 原厂 DTB 反编译 + OpenWrt 官方仓库/mailing list 资料
> 采集时间：2026-10-12　设备：aigo AGS21 / MT7981B / 1GB DDR4 / 64GB eMMC

---

## 一、结论（TL;DR）

1. **OpenWrt 官方目前不支持 AGS21。** 官方 `mediatek/filogic` 的 dts 目录里只有
   cmcc-rax3000m / openwrt-one / xiaomi / zbtlink / zyxel / confiabits / unielec，
   没有 aigo 任何型号。Table of Hardware 里也查不到。
2. **但 AGS21 的硬件与「CMCC RAX3000M eMMC 版」高度同构**，而 RAX3000M eMMC 版
   **是官方正式支持的**（23.05.1 起，当前 25.12.x）。
   最关键的一点：官方 RAX3000M eMMC 的 U-Boot 定义是
   `BL2_BOOTDEV:=emmc` + **`BL2_DDRTYPE:=ddr4`**，与 AGS21 实测的 DDR4 **完全吻合**；
   fip 分区位置（LBA 13312，8192 扇区）也**完全一致**。分区布局是同一套。
3. 所以有两条路：
   - **快路**：直接刷官方 RAX3000M eMMC 固件 → 能开机上网，但有 4 处硬伤
     （LED 全错、LAN 口数量/标签对不上（AGS21 机身只有 2 个 LAN）、只用 512MB 内存、WPS 键失效）。
   - **正路**：写 AGS21 自己的 dts 并用官方源码树编译 → 这才是「官方 OpenWrt」，
     再走 PR 可以进官方。
4. 原厂固件本身就是 OpenWrt：`OpenWrt 21.02-SNAPSHOT`，target `mediatek/mt7981`，
   `board_name = mediatek,mt7981-emmc-rfb`（即 MTK 官方 RFB 参考板的 eMMC 版 BSP）。
   换句话说 **原厂就是老版本 OpenWrt**，换新官方版是「升级」而非「跨系统」。

---

## 二、实机硬件画像（实测，非推测）

| 项目 | 实测值 | 来源 |
|---|---|---|
| SoC | MT7981B，2× Cortex-A53 @1300MHz | `/proc/cpuinfo`、BROM 握手 |
| DRAM | **1024 MB DDR4** | BL2 日志 `EMI: Using DDR4 settings` |
| eMMC | 64GB（Longsys CG6XAK，manfid 0x51），122,159,104 扇区 | `/sys/block/mmcblk0/device/*` |
| 原厂系统 | OpenWrt 21.02-SNAPSHOT / Linux 5.4.246 / `LLXQ-MTK-S21B1-V20250613` | `/etc/os-release` |
| 兼容串 | `mediatek,mt7981-emmc-rfb`，model `MediaTek MT7981 RFB` | `/proc/device-tree/compatible` |
| 原厂 U-Boot | `2022.10-gf2fa0b94-dirty`（MTK vendor，含 mtkupgrade/httpd 恢复菜单、签名校验、双启动） | `chosen/u-boot,version` + p1 env |
| 交换芯片 | **MT7531** @ MDIO 0x1f，reset GPIO39；原厂 DTS 声明 PHY0-3 共 **4 个 LAN 口**，但**机身实际只有 2 个 LAN 插座**（用户实机确认）；原厂 `02_network` 默认分支也只把 `lan4 lan3 lan2` 桥进 br-lan、把 `lan1` 当 iptv_port，属 MTK 参考板通用配置，不代表真实接线。**2026-10-13 实测定稿：两个 LAN 插座接在 PHY1/PHY2，且与面板丝印 LAN1/LAN2 同序 → 对应 dts 的 `port@1`(lan1)/`port@2`(lan2)，PHY0/PHY3 未接线** | 原厂 DTS `switch@0` + `/etc/board.d/02_network` + 实机 carrier 轮询 + `dmesg` |
| WAN | gmac1 + SoC 内置 GbE PHY（`ethernet-phy-id03a2.9461`） | 原厂 DTS `mac@1` |
| WiFi | MT7976（SoC 内置），原厂用 **MTK 私有驱动** `mt_wifi.ko`（ra0/rax0/apcli0） | `lsmod`、`iw dev` 为空 |
| WiFi EEPROM | **factory 分区（mmcblk0p2）偏移 0**，首 4 字节 `81 79 00 00` = 0x00007981 | `l1profile.dat` + p2 dump |
| 按键 | reset = GPIO1 **ACTIVE_LOW**；wps = GPIO0 **ACTIVE_HIGH** | 原厂 DTS `gpio-keys` |
| LED | red GPIO6 / green GPIO4 / internet GPIO29，全部 **ACTIVE_LOW**，red 默认常亮 | 原厂 DTS `gpio-leds` |
| USB | `xhci` + `usb-phy` 原厂即 `okay`（有控制器，未焊座） | 原厂 DTS |
| 分区 | p1 u-boot-env / p2 factory / p3 fip@13312 / p4 kernel / p5 rootfs / p6 permanent_config | GPT + 实机 |
| MAC 存储 | factory 分区内 4 个 MAC（…:49 / :4a / :4b / :4c） | p2 dump |

---

## 三、AGS21 与官方 RAX3000M eMMC 的差异清单

这份表就是「为什么不能无脑刷 RAX3000M 固件」的答案。

| 项目 | AGS21（实测） | RAX3000M eMMC（官方 dts） | 影响 |
|---|---|---|---|
| memory | `0x40000000` = **1GB** | `0x20000000` = 512MB | 刷 RAX 固件 → 只认 512MB，浪费一半 |
| LED | GPIO **6 / 4 / 29** | GPIO **9 / 12 / 35** | 刷 RAX 固件 → 灯全乱，可能点亮无意义的 GPIO |
| 按键 wps | GPIO0 **ACTIVE_HIGH** | GPIO0 **ACTIVE_LOW**（mesh） | 刷 RAX 固件 → 该键电平反相 |
| LAN 口 | 机身**只有 2 个 LAN 插座**，面板丝印 WAN / LAN1 / LAN2（原厂 dts 声明 PHY0-3 是参考板写法）；WAN 走 gmac1+内置 PHY | 官方声明 **3** 个（PHY0-2，label 依次 lan3/lan2/lan1） | 刷 RAX 固件：多出 1 个空接口、标签错位。**实测已定案：本机插座在 PHY1/PHY2，官方 dts 的 PHY0/1/2 覆盖得到，因此功能上不会不通，只是官方那块板是按它自己的面板丝印命名的**；PHY3 未接线，官方没声明它也没关系。我们的 dts 按本机面板丝印命名：`port@1`=lan1、`port@2`=lan2 |
| 交换 PHY | MT7531 内置 PHY | 新版用 Airoha **AN8855** MFD + 内部 PHY | 端口映射/PHY 驱动路径不同 |
| WiFi 驱动 | MTK 私有 `mt_wifi` | 主线 `mt76` | 换系统必须换驱动，EEPROM 位置恰好相同（都在 factory@0）|
| U-Boot | MTK vendor，签名 + 双启动 | 必须换成 OpenWrt U-Boot | **必须替换**，否则无法引导 mainline 内核 |

**相同的部分（关键利好）**：SoC、DDR4、eMMC、GPT 布局、fip 偏移 13312、EEPROM 位置、
gmac0→MT7531 2500base-x、gmac1→内置 PHY 作 WAN、xhci/usb_phy 使能状态。

---

## 四、三条路线对比

| | 路线 A：直接刷 RAX3000M 官方固件 | 路线 B：自编固件（AGS21 dts）+官方源码 | 路线 C：正式提交官方 PR |
|---|---|---|---|
| 工作量 | 最低（1 小时） | 中（半天，需 Linux 编译环境） | 高（数天~数周，含 review） |
| 是否「官方 OpenWrt」 | 是官方产物，但设备型号不是 AGS21 | 内核/软件源是官方，设备定义自持 | 完全官方 |
| 功能完整性 | LED 乱 / LAN 口数+标签需实测校正 / 512MB / WPS 失效 | 完整 | 完整 |
| kmod 官方源可用 | ✔ | ✔（改动仅限 dts，不动内核模块 ABI） | ✔ |
| 风险 | 低（社区已验证） | 低-中 | 中（需维护） |

**推荐顺序：先走 A 验证「能不能跑通 TFTP 恢复 + sysupgrade」，
再用 B 把 AGS21 的功能补全。C 是可选的长期目标。**

恩山论坛的实测结论与路线 A 一致（帖主 debian：*"直接刷 RAX3000M EMMC 版固件吧，
不维护了"*；帖主 lotusswan 用 hanwckf 系 U-Boot + 自编 24 版固件也刷成功了）。

---

## 五、路线 A 详细步骤（最快见效）

> ⚠️ 全程会覆盖 eMMC 的 boot0 区与 LBA 13312 起的 fip 区。
> **设备全部分区已于 2026-10-12 完整备份到 `ags21_backup/`（10 个 img.gz + manifest + 校验），
> 且已用 mtk_uartboot 走 BROM 的救砖通道验证过串口可用。**
> 刷机前请再确认手头有：USB-TTL（COM5）、`mtk_uartboot.exe`、`mt7981-ddr4-bl2.bin`。

### 5.1 准备官方文件

从 OpenWrt firmware selector 选 `mediatek/filogic` + `CMCC RAX3000M (eMMC)`（**必须 eMMC 版**，不要 NAND 版）：

| 文件 | 用途 |
|---|---|
| `…-cmcc_rax3000m-emmc-preloader.bin` | BL2（**DDR4**，刷到 `mmcblk0boot0`） |
| `…-cmcc_rax3000m-emmc-bl31-uboot.fip` | BL31+U-Boot（刷到 LBA 13312） |
| `…-cmcc_rax3000m-emmc-initramfs-kernel.bin` | TFTP 恢复用 initramfs |
| `…-cmcc_rax3000m-emmc-squashfs-sysupgrade.bin` | 正式固件（sysupgrade 刷入） |

> 23.05 / 24.10 的 `emmc-preloader.bin` 与 SNAPSHOT 的 `emmc-ddr4-preloader.bin` 是两套。
> **AGS21 是 DDR4，务必确认文件名带 ddr4（SNAPSHOT/25.12 起为默认）**，否则 BL2 起不来。

### 5.2 写入 BL2（eMMC boot0 区）

```sh
# 先解除写保护
echo 0 > /sys/block/mmcblk0boot0/force_ro

dd if=/dev/zero of=/dev/mmcblk0boot0 bs=512 count=8192 conv=fsync
dd if=/tmp/preloader.bin of=/dev/mmcblk0boot0 bs=512 conv=fsync
```

### 5.3 写入 FIP（LBA 13312，8192 扇区 = 正好是 p3 分区）

```sh
dd if=/dev/zero of=/dev/mmcblk0 bs=512 seek=13312 count=8192 conv=fsync
dd if=/tmp/bl31-uboot.fip of=/dev/mmcblk0 bs=512 seek=13312 conv=fsync
sync
```

### 5.4 TFTP 恢复

1. PC 网线接设备 **LAN 口**，设静态 IP `192.168.1.254 / 255.255.255.0`。
2. 起 TFTP 服务（tftpd64 等），把 `initramfs-kernel.bin` 放进根目录。
3. 设备**断电 → 上电**，OpenWrt U-Boot 会自动 TFTP 拉取并启动。
   （若未自动，串口进 U-Boot 后 `dhcp` 或 `tftpboot 0x46000000 <文件名>` 后 `bootm`。）
4. 进入 OpenWrt（默认 `192.168.1.1`，无密码）。

### 5.5 固化

```sh
# 在 initramfs 里执行
sysupgrade -n /tmp/squashfs-sysupgrade.bin
```

可选：把 initramfs 写进 p4 做 eMMC 恢复引导（掉电也能自恢复）：

```sh
dd if=initramfs-recovery.itb of=/dev/mmcblk0p4 bs=512 conv=fsync
```

### 5.6 刷完后的预期问题（对照第三章）

- 灯：red/green/internet 全部不亮或乱闪
- 网口：官方 dts 会创建 `lan3`(=MT7531 PHY0)、`lan2`(=PHY1)、`lan1`(=PHY2) 三个接口，
  但机身只有 2 个 LAN 插座 → 必有一个是空接口；且**哪个 netdev 对应哪个插座必须实测**
  **（已实测完毕）**：本机插座在 PHY1/PHY2 → 官方固件下是 `lan2`/`lan3` 两个口，`lan3`(=PHY0)
  是空接口。改用我们的 dts 后只声明 `port@1`/`port@2`。
  端口名**对齐面板丝印**（面板印的是 WAN / LAN1 / LAN2）：`port@1`(PHY1)=**lan1**、
  `port@2`(PHY2)=**lan2**，与上游对 rax3000m 的做法一致（官方那块板的 `port@0/1/2` 就故意写成
  `lan3/lan2/lan1`，说明「label 要对丝印」才是约定）。改名后已存在配置的迁移见
  `build/99-ags21-port-rename`。
- `free` 只显示 512MB
- WPS/reset 键行为异常

这些正是路线 B 要修的。

---

## 六、路线 B：AGS21 专属固件（改动清单）

已产出的草案文件：**`mt7981b-aigo-ags21.dts`**（本目录），可直接拷进
`target/linux/mediatek/dts/`。其余改动如下。

### 6.1 `target/linux/mediatek/image/filogic.mk`

```make
define Device/aigo_ags21
  DEVICE_VENDOR := AIGO
  DEVICE_MODEL := AGS21
  DEVICE_DTS := mt7981b-aigo-ags21
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7915-firmware kmod-mt7981-firmware \
	kmod-usb3 kmod-mtk-sd-ecc kmod-mmc mtk-sd-ecc
  SUPPORTED_DEVICES += aigo,ags21
  DEVICE_DTS_LOADADDR := 0x4ff00000
endef
TARGET_DEVICES += aigo_ags21
```

> eMMC 设备需要 `Build/mt798x-gpt` 生成 GPT 布局；如果沿用 RAX3000M 的分区方案，
> 直接参考 `cmcc_rax3000m-emmc` 的 `ARTIFACT/...` 写法即可。**AGS21 现有 GPT 布局与
> RAX3000M 一致，无需改动分区表**（这也是路线 A 能直接刷的原因）。

### 6.2 `package/boot/uboot-mediatek/Makefile`

```make
define U-Boot/mt7981_aigo_ags21
  NAME:=AIGO AGS21
  BUILD_SUBTARGET:=filogic
  BUILD_DEVICES:=aigo_ags21
  UBOOT_CONFIG:=mt7981_aigo_ags21
  UBOOT_IMAGE:=u-boot.fip
  BL2_BOOTDEV:=emmc
  BL2_SOC:=mt7981
  BL2_DDRTYPE:=ddr4          # ← 与 RAX3000M emmc 相同
  DEPENDS:=+trusted-firmware-a-mt7981-emmc-ddr4
endef
```

并在 `UBOOT_TARGETS` 列表里追加 `mt7981_aigo_ags21`。
`trusted-firmware-a-mt7981-emmc-ddr4` 已经存在（RAX3000M 在用），无需新增 package。

还需新增（可 90% 复制 RAX3000M 的 `437-add-cmcc_rax3000m.patch`）：
- `configs/mt7981_aigo_ags21_defconfig`
- `arch/arm/dts/mt7981-aigo-ags21.dts`（U-Boot 内部 dts，只要 ddr/mmc/gpio/uart 够用）
- env 文件 `aigo_ags21_env`

### 6.3 `target/linux/mediatek/filogic/base-files/` 下的脚本

| 文件 | 改动 |
|---|---|
| `etc/board.d/01_leds` | 加 `aigo,ags21)` 分支，映射 green→`green:status`、internet→`green:wan` |
| `etc/board.d/02_network` | 加 `aigo,ags21)` 分支：`ucidef_set_interfaces_lan_wan "lan1 lan2" eth1`（实测定稿：两个 LAN 插座在 MT7531 **PHY1/PHY2**，即 dts 的 `port@1`/`port@2`；端口名对齐面板丝印 LAN1/LAN2 = lan1/lan2，与上游 rax3000m 同思路）|
| `etc/uci-defaults/99-ags21-port-rename` | **新增**：端口改名后把已存在配置里的 `br-lan` ports 从 `lan2/lan3` 迁到 `lan1/lan2`（`/etc/config/network` 只在为空时生成，升级时不会自动更新）|
| `etc/hotplug.d/ieee80211/11_fix_wifi_mac` | 从 factory 分区读 MAC（4 个，偏移见 p2 dump） |
| `etc/hotplug.d/firmware/11-mt76-caldata` | 从 **factory 分区偏移 0** 提 EEPROM（与 RAX3000M 同逻辑） |
| `lib/upgrade/platform.sh` | 加 `aigo,ags21)` → `emmc_do_upgrade` |
| `package/boot/uboot-envtools/files/mediatek_filogic` | 加 AGS21 的 u-boot-env 设备（`mmcblk0p1`，0x0/0x40000/0x40000） |

### 6.4 附加软件包（WireGuard / ddns-go / homeproxy / 首页面板）

| 需求 | 来源 | 落地方式 |
|---|---|---|
| WireGuard | **官方 feed** | `kmod-wireguard` + `wireguard-tools` + `luci-proto-wireguard`。中文界面由 `luci-base` 的 `base.po` 带出（该包**没有**独立中文包，见下）。二维码是纯前端的 `luci-lib-uqr`，**不需要 qrencode** |
| qrencode（命令行二维码） | **官方 feed**（`libs/qrencode`，4.1.1） | 只提供 `/usr/bin/qrencode` 给脚本/终端用；**WireGuard 界面二维码不走它** |
| ddns-go | **ImmortalWrt** | 官方 feed 只有 `ddns-scripts`（定位完全不同）；由 `build/vendor.sh` 按固定 commit 搬，含 LuCI 界面 |
| homeproxy | **ImmortalWrt** | 官方 feed 没有；同样由 `vendor.sh` 搬。`sing-box` 本体官方 feed **有**（1.12.x），所以只搬 LuCI 界面那一层 |
| 首页「温度」/「CPU 使用率」两行 | **本仓库自带包 + 一处注入** | 「系统」块内部的两行（对齐 ImmortalWrt 排版）：`build/ags21-status-rows.js` 是被 `build-ags21.sh` 锚点注入到上游 `luci-mod-status/10_system.js` 的 JS 片段；`packages/luci-app-ags21-dashboard` 现在只装那份 rpcd ACL |

要点（都是实测核对过的，不是推测）：

- **homeproxy 的依赖全部可满足**：`sing-box` ✓（官方 `net/sing-box` 1.12.17）、
  `firewall4` ✓、`kmod-nft-tproxy` / `kmod-nft-socket` ✓、`ucode-mod-digest` ✓、
  `ucode-mod-math` ✓、`rpcd-mod-ucode` ✓。官方 `sing-box` 已定义 `USERID:=sing-box=5566`，
  homeproxy 的 `procd_add_jail ... user sing-box` 才起得来。
  它**不需要 chinadns-ng** —— init 脚本只调用 `/usr/bin/sing-box`，
  DNS 分流靠 sing-box 自己监听 `127.0.0.1` + dnsmasq 的 `nftset=`。
- **`ucode-mod-math` 是 homeproxy 上游漏声明的依赖**（要显式钉住）：
  `generate_client.uc:11` 有 `import { isnan } from 'math'`（第 177 行在用），
  但上游 `LUCI_DEPENDS` 只写了 `+ucode-mod-digest`。它能跑纯粹因为 `luci-base`
  顺带带上了它（`luci-base/ucode/dispatcher.uc:8` 也 import math）。
  已在本项目配置里显式写死，不依赖这个巧合。
  全镜像 104 条 ucode 模块引用已逐条核对可解析。
- 设备上 `dnsmasq` 2.93 **已带 `nftset`**（`dnsmasq --version` 可见），
  所以**不用**换成 `dnsmasq-full`。
- **温度有三路，只有一路在 thermal 子系统里**（串口实测）：`/sys/class/hwmon/`
  下是 `cpu_thermal`（≈55 °C）、`mt7915_phy0`（≈44 °C）、`mt7915_phy1`（≈44 °C）——
  两个无线芯片的结温由 MT76 驱动注册成 hwmon，`/sys/class/thermal` 里**只有 SoC**。
  所以这两行走 hwmon，输出格式与 ImmortalWrt 的 `/sbin/tempinfo` 逐字一致
  （`CPU: 58.4°C, WiFi: 44.0°C 44.0°C`）。
  **扩展方式有两种，选的是第二种**：往 `/www/luci-static/resources/view/status/include/`
  丢 `.js` 只能加「独立面板」，加不了「系统块内部的行」；要后者就得改
  `luci-mod-status` 的 `10_system.js` 的 `fields` 数组，本项目用锚点注入做。
  ACL 要用 `fnmatch`（`FNM_NOESCAPE`，`*` 跨 `/`）的通配语义一次覆盖 hwmon 的动态编号
  —— 原理与实测见 `build/README.md` 第 9 节。
- 这台机器**没有 cpufreq**（`/sys/devices/system/cpu/cpufreq/` 是空的，
  dts 里也没有 `operating-points-v2`），所以面板不显示频率。
- vendor 进来的包必须打两处补丁（相对 `include` 路径 + 显式版本号），
  原因见 `build/README.md` 第 10 节。
- **官方 sing-box 默认不编 `with_acme` —— 这是 homeproxy 的硬需求**：homeproxy 的
  `generate_server.uc` 会生成 `acme: {...}` 块（服务端自动申请 TLS 证书），必须打开
  `CONFIG_SINGBOX_WITH_ACME=y`（连带 `CONFIG_SINGBOX_WITH_DHCP=y` 对齐 ImmortalWrt），
  否则启用服务端时 sing-box 会因不识别该字段启动失败。官方包 tag 由 config 驱动，
  打开即生效。官方 1.12.17 与 ImmortalWrt 1.12.25 同属 1.12.x，配置格式兼容，
  不必换整包。详见 `build/README.md` 第 10 节。
- WireGuard **没有独立的中文语言包**：官方 `luci-proto-wireguard` 不带 `po/` 目录，
  所以不存在 `luci-i18n-wireguard-zh-cn` 这个包（写进配置会被 `make defconfig`
  静默丢弃）。界面中文来自 `luci-base` 的 `base.po`。为防这类「未知符号被悄悄丢掉」，
  `build-ags21.sh` 现在会在 `make defconfig` **之后**回读 `REQUIRED_CONF`，缺一项即中止。
- 本轮实测：加上这些包后镜像从 12.06 MB 涨到 27.53 MB（+15.5 MiB），大头是
  `sing-box`（未压缩 41.8 MB）与 `ddns-go`（未压缩 10.8 MB）。
- sing-box 补齐 ACME/DHCP 后，实测二进制内嵌的 build tags 为
  `with_acme,with_clash_api,with_dhcp,with_gvisor,with_quic,with_tailscale,with_utls,with_wireguard`
  —— 与 ImmortalWrt 那份**逐字一致**（用 `strings usr/bin/sing-box | grep with_acme` 可验，
  对照实验：未编的 `with_embedded_tor`/`with_grpc` 均搜不到）。

### 6.5 编译

```sh
git clone https://github.com/openwrt/openwrt && cd openwrt
# 套用上面的改动
./scripts/feeds update -a && ./scripts/feeds install -a
make menuconfig      # Target: MediaTek / Filogic；Profile: AIGO AGS21
make -j$(nproc) download && make -j$(nproc)
```

产物：`bin/targets/mediatek/filogic/openwrt-mediatek-filogic-aigo_ags21-*.bin`
（含 preloader / bl31-uboot.fip / initramfs / sysupgrade），刷机步骤同第五章。

### 6.6 提交官方 PR（路线 C）

1. 拆成多个 commit：`mediatek: add AIGO AGS21 support`、`uboot-mediatek: add AIGO AGS21`
2. 附 Wiki 设备页（toh）与实机验证记录
3. 发到 `openwrt-devel@lists.openwrt.org` 并开 GitHub PR
4. 常见 review 意见：dts 命名规范、`compatible` 是否与 vendor 一致、
   是否需要 `DEVICE_DTS_LOADADDR`、LED/按键 label 是否遵循 `function/color` 新规范

---

## 七、风险与回退

| 风险 | 概率 | 回退手段 |
|---|---|---|
| 刷错 DDR 类型 preloader → 上电无输出 | 中 | **BROM 恢复**：`mtk_uartboot -s COM5 -p mt7981-ddr4-bl2.bin -a -f <fip>` |
| U-Boot 起不来 / TFTP 失败 | 中 | 串口进 U-Boot 手动 `tftpboot`；或 BROM 重刷 |
| 刷完官方固件后想回原厂 | 低 | 用 `ags21_backup/` 恢复：`boot0.img.gz` → mmcblk0boot0；`p3.img.gz` → LBA 13312；必要时 `p4/p5` 同步恢复 |
| WiFi 起不来（EEPROM 格式不匹配） | 中 | 保留 factory 分区不动；必要时把 p2 的 EEPROM 提取成文件喂给 mt76 |

**绝对不要做的事**：
- 不要动 `p2 factory` 分区（EEPROM + MAC + 射频校准，丢了 WiFi 就废了）
- 不要刷 NAND 版固件
- 不要在 preloader DDR 类型不确定的情况下上电（先用 mtk_uartboot 从 RAM 里试跑）

---

## 八、待实测确认项

1. LED `led-boot/led-running` 极性 —— 原厂 red 默认常亮，可直接当 boot 指示。
2. MT7531 中断脚（GPIO38）是否已焊 —— 决定 dts 里要不要写 interrupt-controller。
3. **【最高优先，上电后立刻做】** 面板上 2 个 LAN 插座分别对应 MT7531 的哪个 PHY
   （原厂 dts 声明 4 个、机身只有 2 个插座）。测法：逐个插座插网线，看
   `for i in /sys/class/net/lan*; do echo "$i $(cat $i/carrier)"; done` 里哪个从 0 变 1；
   PHY 与网名对应关系可用 `ls -l /sys/class/net/lan*/phydev` 或 dmesg 里的
   `PHY [mt7530-0:0X]` 确认。定稿后删掉多余 port 并按面板丝印重排 label。
4. factory 分区完整 2MB 里，5G 段 EEPROM 的确切偏移（当前只确认前 0xD88 有数据）。
5. 1GB DDR4 是否为**单 rank** —— 影响 U-Boot defconfig 的 DRAM 参数（RAX3000M 是 512MB 单 rank）。

---

## 九、资料索引

| 内容 | 链接/位置 |
|---|---|
| 原厂 DTS（反编译） | `ags21_backup/dts/original_ags21.dts`（688 行，107 节点） |
| 原厂 DTB 原始文件 | `ags21_backup/dts/original_ags21.dtb` |
| 外设采集记录 | `ags21_backup/dts/peripheral_dump.txt` |
| 分区表存档 | `ags21_backup/GPT_LAYOUT.txt` |
| 全分区备份 | `ags21_backup/*.img.gz` + `manifest.json` |
| 官方 RAX3000M dts | `openwrt/target/linux/mediatek/dts/mt7981b-cmcc-rax3000m.dts` |
| 官方 RAX3000M U-Boot 定义 | `openwrt/package/boot/uboot-mediatek/Makefile`（`mt7981_cmcc_rax3000m-emmc`, DDR4） |
| 官方设备页/刷机流程 | https://openwrt.org/toh/cmcc/rax3000m |
| 社区 U-Boot（AGS21 已适配） | https://github.com/Yuzhii0718/bl-mt798x-dhcpd |
| hanwckf U-Boot 使用说明 | https://cmi.hanwckf.top/p/mt798x-uboot-usage |
| BROM 救砖工具 | https://github.com/981213/mtk_uartboot |
| 恩山刷机帖（AGS21） | right.com.cn/forum/thread-8461726、thread-8468998 |
