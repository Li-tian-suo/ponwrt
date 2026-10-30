include $(TOPDIR)/rules.mk

PKG_NAME:=air-en8811h-firmware
PKG_RELEASE:=1
PKG_LICENSE:=Proprietary

include $(INCLUDE_DIR)/package.mk

define Package/air-en8811h-firmware
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=Airoha EN8811H 2.5G PHY firmware
  DEPENDS:=+kmod-phy-airoha-en8811h
endef

define Package/air-en8811h-firmware/install
	$(INSTALL_DIR) $(1)/lib/firmware
	$(INSTALL_DATA) ./files/EthMD32.DSP.bin $(1)/lib/firmware/
	$(INSTALL_DATA) ./files/EthMD32.dm.bin $(1)/lib/firmware/
endef

$(eval $(call BuildPackage,air-en8811h-firmware))
