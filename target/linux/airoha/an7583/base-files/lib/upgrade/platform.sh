RAMFS_COPY_BIN='fitblk fit_check_sign'

REQUIRE_IMAGE_METADATA=1

airoha_require_ubi_layout()
{
	local ubidev volume fip_volume

	ubidev="$(nand_find_ubi ubi)"
	[ -n "$ubidev" ] || {
		echo "UBI is not initialized; create the base volumes from U-Boot recovery."
		return 1
	}

	for volume in fip ubootenv ubootenv2 "$@"; do
		if ! nand_find_volume "$ubidev" "$volume" >/dev/null; then
			echo "UBI base volume $volume is missing; repair the layout from U-Boot recovery."
			return 1
		fi
	done

	fip_volume="$(nand_find_volume "$ubidev" fip)"
	[ "$(cat "/sys/class/ubi/$fip_volume/data_bytes")" -gt 0 ] || {
		echo "The fip volume does not contain BL31/U-Boot; install the boot chain first."
		return 1
	}
}

nokia_initial_setup()
{
	[ "$(rootfs_type)" = "tmpfs" ] || return 0

	fw_setenv bootcmd "flash read 0xc0000 0x800000 0x85000000; bootm 0x85000000"
}

platform_check_image() {
	local board=$(board_name)

	case "$board" in
	nokia,xg-040g-mf-ubi|\
	fiberhome,hg5380a-ubi|\
	fiberhome,hg5580a-ubi)
		fit_check_image "$1"
		return $?
		;;
	*)
		nand_do_platform_check "$board" "$1"
		return $?
		;;
	esac

	return 0
}

platform_do_upgrade() {
	local board=$(board_name)

	# HG5380A/HG5580A (UBI) 必须走 fit_do_upgrade，不能落进 nand_do_upgrade
	# 的默认分支。
	#
	# 这两个板子的内核命令行是
	#
	#     rootwait ubi.block=0,fit ubi.fm_autoconvert=1
	#
	# 也就是 rootfs 由 UBI 卷 fit 提供，内核在 fitblk 层把它映射成 /dev/fit0
	# 和 /dev/ubiblock0_7。它们的 DT 里 chosen/rootdisk 指向的就是 fit 卷的
	# phandle。
	#
	# nand_do_upgrade 完全不知道 fitblk 的存在，它只按 CI_KERNPART 删除并重建
	# 一个 UBI 卷，而这个变量在没被赋值时默认是 "kernel"。于是升级会
	#
	#     ubirmvol -N kernel ; ubimkvol -N kernel -s <新镜像长度>
	#
	# 也就是把新固件写进一个叫 kernel 的卷里，而 U-Boot 与内核都不看那个
	# 卷。实测后果（2026-11-11）：sysupgrade 返回 246，ubus 报
	# "Connection failed"，设备重启后仍然跑旧固件，同时 UBI 里多出一个
	# 33902592 字节的 kernel 卷，把最后两个空闲 PEB 也吃掉，
	# avail_eraseblocks 从 2 掉到 0，下一次连卷都建不出来。
	#
	# fit_do_upgrade 会先调 export_fitblk_bootdev()，用 chosen/rootdisk 的
	# phandle 去比对 /sys/class/mtd/ 下各卷的 phandle，得出真正的卷名并导出
	# 为 CI_KERNPART（本板是 "fit"），再交给 nand_do_upgrade。an7581 的
	# platform.sh 一直是这么处理 fiberhome,hg5382a 等板子的，an7583 这一支
	# 漏了，所以只有 nokia 有 fit 路径。
	case "$board" in
	fiberhome,hg5380a-ubi|\
	fiberhome,hg5580a-ubi|\
	nokia,xg-040g-mf-ubi)
		airoha_require_ubi_layout bosa ri && fit_do_upgrade "$1"
		;;
	*)
		nand_do_upgrade "$1"
		;;
	esac
}

platform_pre_upgrade() {
	local board=$(board_name)

	case "$board" in
	nokia,xg-040g-mf)
		nokia_initial_setup
		;;
	*)
		;;
	esac
}
