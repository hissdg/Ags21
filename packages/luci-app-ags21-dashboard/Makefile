#
# AGS21 OpenWrt port — 首页「系统」面板扩展用的 rpcd 授权
#
# 这个包**只装一个 ACL json**。首页那两行「温度」「CPU 使用率」不是独立面板，
# 而是被 build/build-ags21.sh 按锚点注入到上游 feeds/luci 的
# luci-mod-status/htdocs/.../status/include/10_system.js 里的（注入内容见
# build/ags21-status-rows.js）。注入的代码在前端用 fs.read/fs.list 直接读
# /proc/stat 与 /sys/class/hwmon —— 走的就是 rpcd 的 `file` 对象，
# 所以这份 ACL 是**功能必需**：没有它，非 root 会话读不到，两行会显示 '?'。
#
# 历史：这个包早先装的是两个独立的 include 面板
#   （15_cpu_usage.js / 61_wifi_temp.js）。因为用户要求排版与 ImmortalWrt
#   一致（温度/CPU 使用率在「系统」块内部），已经改走上游注入那条路，
#   那两个文件删了。包名保留，省得动 .config 里的包选择。
#
# 本文件是 free software，以 Apache License 2.0 授权。
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-ags21-dashboard
PKG_VERSION:=1.1.0
PKG_RELEASE:=1

PKG_MAINTAINER:=AGS21 OpenWrt port
PKG_LICENSE:=Apache-2.0
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

# 本包没有任何源码，只装一个 ACL json。
# 不写这一段的话，OpenWrt 默认的 Build/Compile 会去 build_dir 里执行
# `make -C $(PKG_BUILD_DIR)`，而那个目录是空的，直接报
#   make[3]: *** No targets specified and no makefile found.  Stop.
# （实测踩过：整个 world 就挂在包上。）显式置空即可。
define Build/Compile
endef

define Package/luci-app-ags21-dashboard
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=AGS21 status overview extension (rpcd ACL for CPU usage / temperature)
  DEPENDS:=+luci-base +luci-mod-status
  PKGARCH:=all
endef

define Package/luci-app-ags21-dashboard/description
  Grants the rpcd permissions used by the AGS21 status overview extension.

  The overview page shows two extra rows inside the built-in "System" panel:

      温度            CPU: 58.4°C, WiFi: 44.0°C 44.0°C
      CPU 使用率（%）  28%

  These rows are injected into the upstream luci-mod-status panel
  (view/status/include/10_system.js) by build/build-ags21.sh; the injected
  code reads /proc/stat and /sys/class/hwmon client-side through rpcd's
  `file` object, which is exactly what this ACL authorises. LuCI itself is
  not otherwise modified.
endef

define Package/luci-app-ags21-dashboard/install
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-ags21-dashboard.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-ags21-dashboard.json
endef

$(eval $(call BuildPackage,luci-app-ags21-dashboard))
