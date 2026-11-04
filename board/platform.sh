#!/bin/sh
#
# AN7583 / FiberHome HG5380A 的 sysupgrade 支持
#
# 布局（与 target/linux/airoha/image/an7583.mk 的配方对应）：
#
#   sysupgrade.bin = [ 内核 FIT，pad 到 KERNEL_SIZE=6144k ] + [ squashfs ] + [ 元数据 ]
#                    ↑ 写 KernelB (mtd4)                    ↑ 写 apps (mtd6)
#
# 偏移 0x5C0000 = 6144k = 46 × 128k，计算方式与 KERNEL_SIZE 保持同步。
#
# 注意：*不能* 把整个 sysupgrade.bin 写进 apps —— 那样会把内核写进根文件
# 系统分区，直接毁掉布局（这个坑踩过一次）。
#
# 用法（在 OpenWrt 里，不需要 U-Boot）：
#   wget -O /tmp/fw.bin http://<pc>:8000/sysupgrade.bin
#   sysupgrade -n /tmp/fw.bin
#

RAMFS_COPY_BIN="mtd"
RAMFS_COPY_DATA=""

KERNEL_BLOCKS=46          # 6144k / 128k
KERNEL_BYTES=$((KERNEL_BLOCKS * 131072))   # 0x5C0000

platform_check_image() {
	local board="$(board_name)"

	case "$board" in
	fiberhome,hg5380a)
		# 头部必须是 FIT（0xd00dfeed）
		#
		# 不能用 get_magic_word：它内部是 `dd bs=2 count=1`，只读 2 个字节，
		# 在这台机器上只会返回 "d00d"，与 8 位魔数永远不相等 —— 任何镜像都
		# 会被判成"不是 FIT"。这里显式读 4 字节。
		[ "$(hexdump -v -n 4 -e '1/1 "%02x"' "$1" 2>/dev/null)" = "d00dfeed" ] || {
			echo "镜像头部不是 FIT，拒绝刷写"
			return 1
		}
		# KERNEL_BYTES 处必须是 squashfs（"hsqs"）
		local magic
		magic=$(dd if="$1" bs=1 skip=$((KERNEL_BYTES)) count=4 2>/dev/null)
		[ "$magic" = "hsqs" ] || {
			echo "偏移 $KERNEL_BYTES 处不是 squashfs，镜像布局不符（KERNEL_SIZE 改过？）"
			return 1
		}
		return 0
		;;
	esac

	return 0
}

platform_do_upgrade() {
	local board="$(board_name)"

	case "$board" in
	fiberhome,hg5380a)
		local img="$1"

		# 1) 内核 → KernelB（与运行中的分区无关，安全）
		echo "写入内核到 KernelB ..."
		dd if="$img" of=/tmp/kernel.bin bs=131072 count=$KERNEL_BLOCKS 2>/dev/null
		mtd write /tmp/kernel.bin KernelB || {
			echo "内核写入失败"
			rm -f /tmp/kernel.bin
			return 1
		}
		rm -f /tmp/kernel.bin

		# 2) 根文件系统 → apps，写完立即重启（mtd -r）
		echo "写入根文件系统到 apps ..."
		dd if="$img" of=/tmp/rootfs.bin bs=131072 skip=$KERNEL_BLOCKS 2>/dev/null
		mtd -r write /tmp/rootfs.bin apps
		;;
	*)
		default_do_upgrade "$1"
		;;
	esac
}
