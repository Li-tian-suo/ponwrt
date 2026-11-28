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

# ---------------------------------------------------------------------------
# FiberHome HG5580A / HG5380A on the vendor partition table
#
# The payload is a raw container (FIT + squashfs + metadata), and the rootfs
# lives in plain MTD partitions.  There is no mtd partition and no UBI volume
# called "rootfs", so the generic nand_do_upgrade path dies with:
#
#   cannot find ubi mtd partition rootfs
#
# The squashfs offset is detected at runtime instead of hardcoded, because the
# kernel padding changes between builds.
# ---------------------------------------------------------------------------
hg5580a_squashfs_offset() {
	local image="$1"
	local n=0 blk

	while [ "$n" -lt 512 ]; do
		blk="$(dd if="$image" bs=128k skip="$n" count=1 2>/dev/null | head -c 4)"
		if [ "$blk" = "hsqs" ]; then
			echo $((n * 131072))
			return 0
		fi
		n=$((n + 1))
	done

	return 1
}

hg5580a_check_image() {
	local image="$1"

	[ "$(dd if="$image" bs=1 count=4 2>/dev/null | hexdump -e '4/1 "%02x"')" = "d00dfeed" ] || {
		echo "invalid image: not a FIT container"
		return 1
	}

	hg5580a_squashfs_offset "$image" >/dev/null || {
		echo "invalid image: no squashfs payload found"
		return 1
	}

	return 0
}

hg5580a_do_upgrade() {
	local image="$1"
	local off blocks

	off="$(hg5580a_squashfs_offset "$image")" || {
		echo "cannot locate the squashfs payload"
		return 1
	}

	blocks=$((off / 65536))
	echo "upgrading: kernel = ${blocks} x 64k, rootfs starts at 0x$(printf '%x' "$off")"

	mtd erase RootfsB || return 1
	dd if="$image" bs=64k skip="$blocks" 2>/dev/null | mtd write - RootfsB || return 1

	mtd erase KernelB || return 1
	dd if="$image" bs=64k count="$blocks" 2>/dev/null | mtd write - KernelB || return 1

	sync
	return 0
}

platform_check_image() {
	local board=$(board_name)

	case "$board" in
	nokia,xg-040g-mf-ubi)
		fit_check_image "$1"
		return $?
		;;
	fiberhome,hg5380a|\
	fiberhome,hg5580a)
		hg5580a_check_image "$1"
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

	case "$board" in
	nokia,xg-040g-mf-ubi)
		airoha_require_ubi_layout bosa ri && fit_do_upgrade "$1"
		;;
	fiberhome,hg5380a|\
	fiberhome,hg5580a)
		hg5580a_do_upgrade "$1"
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
