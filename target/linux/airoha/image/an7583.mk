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

# ---------------------------------------------------------------------------
# FiberHome HG5580A: wrap the OpenWrt FIT in the vendor KernelX container.
#
# The vendor U-Boot 2023.04 `ldkernel` does not boot a bare FIT.  It expects a
# 8448-byte private header followed by a FIT whose header declares
# totalsize = 0x1000 (NOT the FIT's own length); U-Boot uses that declared
# value to locate the payload:
#
#     0x0000..0x2100   private header (X.509 + "HDR2")
#     0x2100           FIT metadata, totalsize = 0x1000
#     0x3100 + off     payload
#     total_size = *(le32)(+0xA0) + *(le32)(+0x98)
#
# The private header carries vendor signing material and cannot be rebuilt
# without FiberHome's private key, so board/hg5580a-vendor-header.bin holds the
# first 0x2100 bytes of a real KernelA dump.
#
# KernelX is 6 MiB, so this only works with the SYSUPGRADE FIT: the initramfs
# kernel embeds the whole rootfs and is ~10.7 MiB.
# ---------------------------------------------------------------------------
HG5580A_MKVENDOR := $(TOPDIR)/scripts/mkvendor-kernel.py
HG5580A_VENDOR_HDR := $(TOPDIR)/board/hg5580a-vendor-header.bin
HG5580A_PYTHON := $(STAGING_DIR_HOST)/bin/python3

define Build/mtd-kernel-bin
	$(HG5580A_PYTHON) $(HG5580A_MKVENDOR) --header $(HG5580A_VENDOR_HDR) --fit $(KDIR_KERNEL_IMAGE) --part-size 0x600000 --out $@ --quiet
endef

# RootfsX is a bare partition.  Copy the PER-DEVICE squashfs, not plain
# root.squashfs: the bare one omits DEVICE_PACKAGES, which would leave the box
# without kmod-airoha-paged-bosa (no optical frontend, no pon0).
define Build/mtd-rootfs-bin
	cp $(KDIR)/root.squashfs$(if $(TARGET_PER_DEVICE_ROOTFS),+pkg=$(ROOTFS_ID/$(DEVICE_NAME))) $@
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
	# 本机光模块是 UX3363（bosacal 分区的 table 写着 ux3363），
	# 只有 kmod-airoha-paged-bosa 里的 airoha-paged-bosa-ux3363.c 能驱动它。
	#
	# 上游 feed 给 airoha-paged-bosa 的 DEPENDS 只写了 @TARGET_airoha_an7581，
	# AN7583 下选不中，由 board/airoha-paged-bosa-an7583.patch 修正。
	# 不加这个包，DTS 的 BOSA 节点无人绑定，airoha-xpon 的 probe 会失败，
	# pon0 根本不出现。
	#
	# 本机 2.5G PHY 是 Motorcomm YT8821（MDIO 0x07，ID 0x4f51ea19），
	# DTS 里用 ethernet-phy-ieee802.3-c22 通用绑定，带 motorcomm 驱动更稳。
	#
	# luci-app-pon 提供 PON 的管理页面（status/config/diagnostics/hardware
	# 四个视图 + airoha-pon-data 后端），数据来源就是 airoha-ponctl 的
	# status/--json。不加这个包，LuCI 里没有 PON 菜单，
	# /usr/lib/lua/luci/controller/ 会是空的，只能用串口敲 ponctl。
	DEVICE_PACKAGES := kmod-phy-motorcomm \
		kmod-airoha-paged-bosa kmod-airoha-en7572 kmod-airoha-xpon \
		airoha-ponctl airoha-pond luci-app-pon
	IMAGES := sysupgrade.bin mtd-kernel.bin mtd-rootfs.bin
	IMAGE/sysupgrade.bin := append-kernel | pad-to 128k | append-rootfs | \
		pad-rootfs | append-metadata

	# ------------------------------------------------------------------
	# 原厂 U-Boot 2023.04 的 ldkernel 不直接启动裸 FIT。它要求一层
	# 8448 字节私有头，并且 FIT 头的 totalsize 字段必须声明为 0x1000
	# （不是 FIT 自身长度），U-Boot 用这个值算 payload 基准地址：
	#
	#   0x0000..0x2100  私有头（含 X.509 与 "HDR2"）
	#   0x2100          FIT 元数据，totalsize = 0x1000
	#   0x3100 + off    payload
	#   total_size = *(le32)(+0xA0) + *(le32)(+0x98)
	#
	# 私有头必须从本机原厂备份复制：它带厂商签名材料，
	# 没有私钥无法重建。放置位置见 board/hg5580a-vendor-header.bin。
	#
	# 生成 mtd-kernel.bin 之前需要先备份 KernelA：
	#   dd if=/dev/mtd2 of=board/hg5580a-vendor-header-raw.bin
	# 脚本会自动截取前 0x2100 字节当作私有头。
	# ------------------------------------------------------------------
	MKVENDOR := $(TOPDIR)/scripts/mkvendor-kernel.py
	VENDOR_HDR := $(TOPDIR)/board/hg5580a-vendor-header.bin
	VENDOR_PY := $(STAGING_DIR_HOST)/bin/python3

	# IMAGE/<name> := 后面跟的是用 | 分隔的 Build/ 命令列表，每个命令名都会
	# 被解析成 Build/<name>。Build/ 函数体必须是单行 —— 带续行和参数的
	# 多行写法会被 split_args 按词拆开，报 "Missing Build/--header"。
	#
	# 注意：$(KDIR_KERNEL_IMAGE) 才是 KERNEL 规则产出的 FIT；
	# $(KDIR)/$(KERNEL_NAME) 是裸 Image。
	# 用 $(STAGING_DIR_HOST)/bin/python3 而不是裸 python3，
	# 否则会被当成缺少的命令名。
	# Build/ 函数定义在文件顶部，不能在 Device/ 块内嵌套 define。
	IMAGE/mtd-kernel.bin := mtd-kernel-bin
	IMAGE/mtd-rootfs.bin := mtd-rootfs-bin

endef
TARGET_DEVICES += fiberhome_hg5580a
