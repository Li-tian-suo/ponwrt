include $(TOPDIR)/rules.mk

PKG_NAME:=air-en8811h-firmware
PKG_RELEASE:=1
PKG_LICENSE:=Proprietary

include $(INCLUDE_DIR)/package.mk

define Build/Compile
endef

define Package/air-en8811h-firmware
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=Airoha EN8811H 2.5G PHY firmware
  DEPENDS:=+kmod-phy-airoha-en8811h
endef

define Build/Compile
endef

define Package/air-en8811h-firmware/install
	# The driver requests "airoha/EthMD32.*.bin", so the files must live in
	# /lib/firmware/airoha/ - not directly in /lib/firmware/.
	$(INSTALL_DIR) $(1)/lib/firmware/airoha
	$(INSTALL_DATA) ./files/EthMD32.DSP.bin $(1)/lib/firmware/airoha/
	$(INSTALL_DATA) ./files/EthMD32.dm.bin $(1)/lib/firmware/airoha/
endef

$(eval $(call BuildPackage,air-en8811h-firmware))