# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2020 Lean <coolsnowwolf@gmail.com>
# Copyright (C) 2021-2023 ImmortalWrt.org

include $(TOPDIR)/rules.mk

PKG_NAME:=autocore
PKG_FLAGS:=nonshared
PKG_RELEASE:=42

PKG_CONFIG_DEPENDS:= \
	CONFIG_TARGET_bcm27xx \
	CONFIG_TARGET_bcm53xx \
	CONFIG_TARGET_x86

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/target.mk

define Package/autocore
  TITLE:=auto core loadbalance script.
  DEPENDS:=@(aarch64||arm||i386||i686||x86_64) \
    +TARGET_bcm27xx:bcm27xx-utils \
    +TARGET_bcm53xx:nvram \
    +TARGET_x86:ethtool \
    +TARGET_x86:lm-sensors
endef

define Build/Compile
endef

define Package/autocore/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/60-autocore-reload-rpcd $(1)/etc/uci-defaults/

ifneq ($(filter i386 i686 x86_64, $(ARCH)),)
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/autocore $(1)/etc/init.d/
endif

	$(INSTALL_DIR) $(1)/sbin
	$(INSTALL_BIN) ./files/cpuinfo $(1)/sbin/
	#
	# airoha 也必须装上 tempinfo。
	#
	# LuCI 总览页那行 "Temperature" 的唯一数据源是 ubus 的
	# luci.getTempInfo，而它只是
	#
	#     if (!access('/sbin/tempinfo')) return {};
	#     const fd = popen('/sbin/tempinfo');
	#
	# 也就是说没有这个脚本就安静地返回空对象，页面直接不渲染那一行，
	# 不会报任何错误。原来的过滤只覆盖 ipq/mediatek/qualcommax，
	# an7583 不在其中，于是温度永远不会显示。
	#
	# 同时 luci-mod-status-autocore.json 里的 ACL 授权
	#     "ubus": { "luci": [ "getCPUInfo", "getTempInfo" ] }
	# 也只有 autocore 会安装，所以 autocore 本身必须进包，否则即使
	# /sbin/tempinfo 存在，非 root 的 LuCI 会话也会被 rpcd 拒绝。
	#
	# an7583 的传感器已经就绪（drivers/thermal/airoha_thermal.c，
	# CONFIG_AIROHA_THERMAL=y，DT 节点在 an7583.dtsi）：
	#     thermal_zone0  cpu-thermal       63100
	#     thermal_zone1  gbe-thermal       64800
	#     thermal_zone2  cpu-die-thermal   62800
	# tempinfo 默认读 thermal_zone0，即 CPU 温度。
ifneq ($(filter ipq% mediatek% qualcommax% airoha%, $(TARGETID)),)
	$(INSTALL_BIN) ./files/tempinfo $(1)/sbin/
endif
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(CP) ./files/luci-mod-status-autocore.json $(1)/usr/share/rpcd/acl.d/
endef

$(eval $(call BuildPackage,autocore))
