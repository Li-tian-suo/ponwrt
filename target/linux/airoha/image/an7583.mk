define Build/an7583-preloader
  $(STAGING_DIR_HOST)/bin/fiptool create \
		--tb-fw $(STAGING_DIR_IMAGE)/an7583-bl2.bin \
		$(STAGING_DIR_IMAGE)/an7583_$1-bl2.fip
  cat $(STAGING_DIR_IMAGE)/an7583_$1-bl2.fip >> $@
endef

define Build/an7583-bl31-uboot
  $(STAGING_DIR_HOST)/bin/fiptool create \
		--soc-fw $(STAGING_DIR_IMAGE)/an7583-bl31.lzma \
		--nt-fw $(STAGING_DIR_IMAGE)/an7583_$1-u-boot.lzma \
		$(STAGING_DIR_IMAGE)/an7583_$1-bl31-u-boot.fip
  cat $(STAGING_DIR_IMAGE)/an7583_$1-bl31-u-boot.fip >> $@
endef

define Device/FitImageLzma
  KERNEL_SUFFIX := -uImage.itb
  KERNEL = kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(DEVICE_DTS).dtb
  KERNEL_NAME := Image
endef

define Device/airoha_an7583-evb
  $(call Device/FitImageLzma)
  DEVICE_VENDOR := Airoha
  DEVICE_MODEL := AN7583 Evaluation Board (SNAND)
  DEVICE_PACKAGES := aeonsemi-as21xxx-firmware kmod-leds-pwm \
	kmod-pwm-airoha kmod-input-gpio-keys-polled
  DEVICE_DTS := an7583-evb
  IMAGE/sysupgrade.bin := append-kernel | pad-to 128k | append-rootfs | \
	pad-rootfs | append-metadata
  ARTIFACT/preloader.bin := an7583-preloader rfb
  ARTIFACT/bl31-uboot.fip := an7583-bl31-uboot rfb
  ARTIFACTS := preloader.bin bl31-uboot.fip
endef
TARGET_DEVICES += airoha_an7583-evb

define Device/airoha_an7583-evb-emmc
  DEVICE_VENDOR := Airoha
  DEVICE_MODEL := AN7583 Evaluation Board (EMMC)
  DEVICE_DTS := an7583-evb-emmc
  DEVICE_PACKAGES := kmod-phy-airoha-en8811h
  ARTIFACT/preloader.bin := an7583-preloader rfb
  ARTIFACT/bl31-uboot.fip := an7583-bl31-uboot rfb
  ARTIFACTS := preloader.bin bl31-uboot.fip
endef
TARGET_DEVICES += airoha_an7583-evb-emmc

define Device/nokia_xg-040g-mf-common
  $(call Device/FitImageLzma)
  DEVICE_VENDOR := Nokia
  DEVICE_MODEL := XG-040G-MF
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  UBINIZE_OPTS := -E 5
  DEVICE_PACKAGES := kmod-phy-airoha-en8811h \
	kmod-regulator-userspace-consumer kmod-usb-ledtrig-usbport kmod-usb3 \
	kmod-airoha-en7572 kmod-airoha-xpon \
	$(AIROHA_USB_STORAGE_PACKAGES)
endef

define Device/nokia_xg-040g-mf
  $(call Device/nokia_xg-040g-mf-common)
  DEVICE_DTS := an7583-nokia_xg-040g-mf
  KERNEL_SIZE := 8192k
  IMAGES += factory-kernel.bin factory-rootfs.bin
  IMAGE/factory-kernel.bin := append-kernel
  IMAGE/factory-rootfs.bin := append-ubi
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += nokia_xg-040g-mf

define Device/nokia_xg-040g-mf-ubi
  $(call Device/nokia_xg-040g-mf-common)
  DEVICE_VARIANT := (UBI)
  DEVICE_DTS := an7583-nokia_xg-040g-mf-ubi
  UBOOTENV_IN_UBI := 1
  KERNEL_IN_UBI := 1
  KERNEL := kernel-bin | gzip
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 128k
  KERNEL_INITRAMFS_SUFFIX := -recovery.itb
  IMAGES := sysupgrade.itb
  IMAGE/sysupgrade.itb := append-kernel | \
	fit gzip $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb external-static-with-rootfs | \
	append-metadata
  DEVICE_PACKAGES += fitblk
  ARTIFACT/bl31-uboot.fip := an7583-bl31-uboot nokia_xg-040g-mf
  ARTIFACT/preloader.bin := an7583-preloader nokia_xg-040g-mf
  ARTIFACTS := bl31-uboot.fip preloader.bin
endef
TARGET_DEVICES += nokia_xg-040g-mf-ubi
# 追加到 ponwrt 的 target/linux/airoha/image/an7583.mk 末尾
#
# 注意：这里不声明 ARTIFACT/preloader.bin 与 ARTIFACT/bl31-uboot.fip。
# 本仓库 tools/ 里没有 fiptool，直接声明会让 target/linux 的 install 阶段
# 报 “staging_dir/host/bin/fiptool: No such file or directory”（Error 127）。
# U-Boot/FIP 由 workflow 里的独立步骤用 TF-A 的 fiptool 组装，见 build-hg5380a.yml。

define Device/fiberhome_hg5380a
	# 原厂 U-Boot 2023.04 的 LZMA 解码器解不了 OpenWrt 产出的 lp=2 数据流
	# （uncompress error 7），改用 gzip，兼容性最好。
	KERNEL_SUFFIX := -uImage.itb
	KERNEL = kernel-bin | gzip | fit gzip $$(KDIR)/image-$$(DEVICE_DTS).dtb
	KERNEL_NAME := Image
	DEVICE_VENDOR := FiberHome
	DEVICE_MODEL := HG5380A
	DEVICE_DTS := an7583-fiberhome-hg5380a
	BLOCKSIZE := 128k
	PAGESIZE := 2048
	KERNEL_SIZE := 6144k
	DEVICE_PACKAGES := kmod-phy-motorcomm \
		kmod-airoha-paged-bosa kmod-airoha-xpon \
		e2fsprogs
	IMAGES := sysupgrade.bin
	IMAGE/sysupgrade.bin := append-kernel | pad-to 128k | append-rootfs | \
		pad-rootfs | append-metadata
endef
TARGET_DEVICES += fiberhome_hg5380a

define Device/fiberhome_hg5580a
	# 原厂 U-Boot 2023.04 的 LZMA 解码器解不了 OpenWrt 产出的 lp=2 数据流
	# （uncompress error 7），改用 gzip，兼容性最好。
	KERNEL_SUFFIX := -uImage.itb
	KERNEL = kernel-bin | gzip | fit gzip $$(KDIR)/image-$$(DEVICE_DTS).dtb
	KERNEL_NAME := Image
	DEVICE_VENDOR := FiberHome
	DEVICE_MODEL := HG5580A
	DEVICE_DTS := an7583-fiberhome-hg5580a
	BLOCKSIZE := 128k
	PAGESIZE := 2048
	KERNEL_SIZE := 6144k
	# 注意：绝对不要加 kmod-airoha-paged-bosa。该包在 openwrt-pon-drivers 里
	# 声明为 DEPENDS:=@TARGET_airoha_an7581，AN7583 下根本不存在这个符号，
	# 打包会直接报 "kmod-airoha-paged-bosa (no such package)"。
	# 本机 2.5G PHY 是 Motorcomm YT8821（MDIO 0x07，ID 0x4f51ea19），
	# DTS 里用 ethernet-phy-ieee802.3-c22 通用绑定，带 motorcomm 驱动更稳。
	DEVICE_PACKAGES := kmod-phy-motorcomm \
		kmod-airoha-en7572 kmod-airoha-xpon \
		airoha-ponctl airoha-pond
	IMAGES := sysupgrade.bin
	IMAGE/sysupgrade.bin := append-kernel | pad-to 128k | append-rootfs | \
		pad-rootfs | append-metadata
endef
TARGET_DEVICES += fiberhome_hg5580a
