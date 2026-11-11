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

# ---------------------------------------------------------------------------
# FiberHome HG5580A (UBI) -- pairs with the U-Boot in uboot-port/.
#
# Differences from the stock-layout variant above:
#   * no vendor KernelX container: the new U-Boot boots a FIT directly
#   * kernel and U-Boot environment live in UBI volumes, not raw partitions
#   * the sysupgrade payload is a single .itb, matching what the U-Boot
#     environment's bootfile_upg expects
#
# 这一段对应实际刷进设备的镜像。上面那个 fiberhome_hg5580a 产出的是
# sysupgrade.bin / mtd-kernel.bin / mtd-rootfs.bin，走原厂分区布局；
# 本板已改成单 UBI 布局（mtd0 all_flash / mtd1 bl2 / mtd2 ubi /
# mtd3 factory / mtd4 bosacal / mtd5 identity），所以要用这个 -ubi 变体。
# ---------------------------------------------------------------------------
define Device/fiberhome_hg5580a-ubi
	$(call Device/FitImageLzma)
	DEVICE_VENDOR := FiberHome
	DEVICE_MODEL := HG5580A
	DEVICE_VARIANT := (UBI)
	DEVICE_DTS := an7583-fiberhome-hg5580a-ubi
	# The platform default (0x80200000, from image/Makefile's loadaddr-y) lands
	# inside the NPU reserved windows declared in an7583.dtsi: those start at
	# 0x84000000, and a 28 MiB lzma payload from 0x80200000 expands past that
	# boundary, so lmb rejects the load with
	#   Unable to allocate memory 0x80200000 for loading OS
	# 0x88000000 is clear of them (NPU ends 0x86e00000) and below U-Boot.
	KERNEL_LOADADDR := 0x88000000
	BLOCKSIZE := 128k
	PAGESIZE := 2048
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
	# fitblk 让内核从 UBI 卷 fit 里读 rootfs（cmdline 有 ubi.block=0,fit）。
	#
	# luci-app-pon 提供 PON 的管理页面（status/config/diagnostics/hardware
	# 四个视图 + airoha-pon-data 后端），数据来源就是 airoha-ponctl。
	# 不加这个包，LuCI 里没有 PON 菜单，/usr/lib/lua/luci/controller/
	# 会是空的，只能用串口敲 ponctl。
	#
	# kmod-nf-conntrack-bridge 是硬件流表卸载的必要条件，不能省。
	#
	# fw4 会同时渲染 inet 和 bridge 两个 flowtable，bridge 那个的链上是
	#
	#     meta l4proto { tcp, udp } flow offload @fb;
	#
	# 而 nft_flow_offload_init() 末行是
	#
	#     return nf_ct_netns_get(ctx->net, ctx->family);
	#
	# 走 NFPROTO_BRIDGE 分支时进入 nf_ct_netns_do_get()：
	#
	#     case NFPROTO_BRIDGE:
	#             if (!nf_ct_bridge_info) {
	#                     if (!retry) { err = -EPROTO; goto out_unlock; }
	#                     request_module("nf_conntrack_bridge");
	#                     ...
	#
	# nf_ct_bridge_info 由 nf_conntrack_bridge.ko 注册，而这个 .ko 只在
	# CONFIG_NF_CONNTRACK_BRIDGE 下编译。缺它时 request_module 必然失败，
	# 规则加载返回 -EPROTO，nft 打印成
	#
	#     Error: Could not process rule: Protocol error
	#             meta l4proto { tcp, udp } flow offload @fb;
	#     The rendered ruleset contains errors, not doing firewall restart.
	#
	# 于是 fw4 拒绝整个规则集 —— 后果不是"offload 没了"，而是任何防火墙
	# 改动都无法生效，且失败是静默的。
	#
	# 实测（2026-11-11，本板）：加这个包之前 fw4 check 必失败；加上之后
	# fw4 check 通过，两个 flowtable（bridge fb / inet ft）都带 flags offload
	# 建起来，规则 flow add @fb / flow add @ft 正常下发。
	DEVICE_PACKAGES := kmod-phy-motorcomm \
		kmod-airoha-paged-bosa kmod-airoha-en7572 kmod-airoha-xpon \
		airoha-ponctl airoha-pond fitblk luci-app-pon \
		kmod-nf-conntrack-bridge
endef
TARGET_DEVICES += fiberhome_hg5580a-ubi
