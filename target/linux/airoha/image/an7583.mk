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

define Device/airoha_an7583-evb-multievb
  $(call Device/FitImageLzma)
  DEVICE_VENDOR := Airoha
  DEVICE_MODEL := AN7583 Evaluation Board (Multi-evb)
  DEVICE_PACKAGES := aeonsemi-as21xxx-firmware kmod-leds-pwm \
	kmod-pwm-airoha kmod-input-gpio-keys-polled kmod-phy-airoha-en8811h
  DEVICE_DTS := an7583-evb-multievb
  DEVICE_DTS_OVERLAY := an7583-evb an7583-evb-emmc
  IMAGE/sysupgrade.bin := append-kernel | pad-to 128k | append-rootfs | \
	pad-rootfs | append-metadata
  ARTIFACT/preloader.bin := an7583-preloader rfb
  ARTIFACT/bl31-uboot.fip := an7583-bl31-uboot rfb
  ARTIFACTS := preloader.bin bl31-uboot.fip
endef
TARGET_DEVICES += airoha_an7583-evb-multievb

define Device/nokia_xg-040g-mf-common
  $(call Device/FitImageLzma)
  DEVICE_VENDOR := Nokia
  DEVICE_MODEL := XG-040G-MF
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  UBINIZE_OPTS := -E 5
  DEVICE_PACKAGES := kmod-phy-airoha-en8811h \
	kmod-regulator-userspace-consumer kmod-usb-ledtrig-usbport kmod-usb3 \
	kmod-airoha-en7572 kmod-airoha-xpon airoha-ponctl airoha-pond \
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

# ---------------------------------------------------------------------------
# FiberHome HG5580A / HG5380A (Airoha AN7583, vendor partition table)
#
# The image is a raw container, not a UBI image and not a tar:
#   FIT (kernel + dtb) padded to the squashfs offset, then squashfs, then the
#   OpenWrt metadata trailer.
# platform.sh writes it into the vendor's inactive A/B slots (KernelB/RootfsB),
# which is why the payload is a .bin and these do not use KERNEL_IN_UBI.
#
# The vendor bootloader's LZMA decoder cannot inflate the lp=2 stream that
# OpenWrt's lzma produces ("Uncompress error 7"), so the kernel is gzip
# compressed here: both the vendor loader and U-Boot understand gzip.
# ---------------------------------------------------------------------------
define Device/fiberhome_hg5580a
  $(call Device/FitImageLzma)
  KERNEL = kernel-bin | gzip | fit gzip $$(KDIR)/image-$$(DEVICE_DTS).dtb
  DEVICE_VENDOR := FiberHome
  DEVICE_MODEL := HG5580A
  DEVICE_DTS := an7583-fiberhome-hg5580a
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_SIZE := 6144k
  # The optical front end is an Airoha UX3363 (paged BOSA) and the 2.5G copper
  # port is a Motorcomm YT8821.  en7572 stays selected so a re-fitted front end
  # still binds; the two drivers match on their own compatible strings.
  DEVICE_PACKAGES := kmod-phy-motorcomm \
	kmod-airoha-paged-bosa kmod-airoha-en7572 kmod-airoha-xpon \
	airoha-ponctl airoha-pond
  IMAGES := sysupgrade.bin
  IMAGE/sysupgrade.bin := append-kernel | pad-to 128k | append-rootfs | \
	pad-rootfs | append-metadata
endef
TARGET_DEVICES += fiberhome_hg5580a

define Device/fiberhome_hg5380a
  $(call Device/FitImageLzma)
  KERNEL = kernel-bin | gzip | fit gzip $$(KDIR)/image-$$(DEVICE_DTS).dtb
  DEVICE_VENDOR := FiberHome
  DEVICE_MODEL := HG5380A
  DEVICE_DTS := an7583-fiberhome-hg5380a
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_SIZE := 6144k
  # Same board as the HG5580A; the copper PHY is an Airoha EN8811H here.
  DEVICE_PACKAGES := kmod-phy-airoha-en8811h \
	kmod-airoha-en7572 kmod-airoha-xpon airoha-ponctl airoha-pond
  IMAGES := sysupgrade.bin
  IMAGE/sysupgrade.bin := append-kernel | pad-to 128k | append-rootfs | \
	pad-rootfs | append-metadata
endef
TARGET_DEVICES += fiberhome_hg5380a
