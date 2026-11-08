include $(TOPDIR)/rules.mk

PKG_NAME:=homebox
PKG_VERSION:=0.2.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

PKG_MAINTAINER:=PonWrt
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/homebox
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Homebox - 内网测速工具（含 LuCI 启停页面）
  URL:=https://github.com/XGHeaven/homebox
  DEPENDS:=+libc
endef

define Package/homebox/description
 Homebox 家庭网络测速工具箱，浏览器端即可压测内网链路，
 最高可测 10G。本包附带 LuCI 启停与端口配置页面。
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/homebox/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/homebox $(1)/usr/bin/homebox

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/homebox.config $(1)/etc/config/homebox

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/homebox.init $(1)/etc/init.d/homebox

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/homebox
	$(INSTALL_DATA) ./files/luci/index.js $(1)/www/luci-static/resources/view/homebox/index.js

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/luci/menu.json $(1)/usr/share/luci/menu.d/luci-app-homebox.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/luci/acl.json $(1)/usr/share/rpcd/acl.d/luci-app-homebox.json
endef

$(eval $(call BuildPackage,homebox))
