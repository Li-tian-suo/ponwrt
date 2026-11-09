# HG5580A 刷机风险与正确路径（2026-11-08）

> **警告**：**不要**在 HG5580A 上直接运行 `sysupgrade`。
> PonWrt 默认的 NAND 升级流程与本机厂商分区布局不兼容，会写坏 flash 导致无法启动。

## 一、为什么 sysupgrade 会毁机

`target/linux/airoha/an7583/base-files/lib/upgrade/platform.sh`（共 76 行）：
**没有 `fiberhome,hg5580a` 的专属分支**，所以走默认路径：

```sh
platform_do_upgrade() {
	local board=$(board_name)

	case "$board" in
	nokia,xg-040g-mf-ubi)
		airoha_require_ubi_layout bosa ri && fit_do_upgrade "$1"
		;;
	*)
		nand_do_upgrade "$1"        # ← HG5580A 落到这里
		;;
	esac
}
```

`nand_do_upgrade` 的前提是 MTD 上存在 **UBI 卷**：

```sh
airoha_require_ubi_layout()
{
	ubidev="$(nand_find_ubi ubi)"
	[ -n "$ubidev" ] || { echo "UBI is not initialized..."; return 1; }

	for volume in fip ubootenv ubootenv2 "$@"; do
		if ! nand_find_volume "$ubidev" "$volume" >/dev/null; then
			echo "UBI base volume $volume is missing..."; return 1
		fi
	done
	...
}
```

它需要 `fip`、`ubootenv`、`ubootenv2` 三个 UBI 卷。

### HG5580A 的真实布局（设备 `cat /proc/mtd` 实测）

```
mtd0  00280000  "bootloader"
mtd1  00080000  "bootflag"
mtd2  00600000  "KernelA"
mtd3  02800000  "RootfsA"
mtd4  00600000  "KernelB"
mtd5  02800000  "RootfsB"
mtd6  02000000  "apps"
mtd7  04800000  "rootfs_data"
mtd8  01000000  "frameworka"
mtd9  01000000  "frameworkb"
mtd10 00500000  "factory"
mtd11 00020000  "bosacal"
mtd12 00020000  "identity"
```

**全是裸 MTD 分区，没有任何 UBI 卷**，更没有 `fip` 卷。

→ `nand_do_upgrade` 会把镜像写到完全错误的位置，**开机即砖**。

## 二、正确的刷机路径

### 2.1 通过 U-Boot 直接写裸分区

镜像结构（已实测验证）：

```
ponwrt-...-squashfs-sysupgrade.bin   13,107,466 B
  @0x000000   FIT (d00dfeed), tot_size = 0x5a6cd8 = 5,926,104 B
  @0x5c0000   squashfs (hsqs), 7,078,154 B
  中间 0x5a6cd8..0x5c0000 共 103,208 B 全 0x00 填充
```

分区容量对照：

| 目标分区 | 容量 | 需要 | 结论 |
| --- | --- | --- | --- |
| KernelB | 0x600000 = 6,291,456 | FIT 5,926,104 | ✅ 放得下 |
| RootfsB | 0x2800000 = 41,943,040 | squashfs 7,078,154 | ✅ 放得下 |

刷机步骤（**先 B 槽，A 槽不动**）：

```
# 1. 切出两个片段（在 PC 上做）
#    kernel.bin   = image[0x000000 : 0x600000]     6,291,456 B
#    rootfs.bin   = image[0x5c0000 : 0x5c0000+0x2800000]  或只取 squashfs 实际长度

# 2. U-Boot 里
tftpboot 0x88000000 kernel.bin
mtd erase KernelB
mtd write KernelB 0x88000000 <len>
mtd read KernelB 0x88000000 <len>   # 回读
crc32 0x88000000 <len>              # 比对

tftpboot 0x88000000 rootfs.bin
mtd erase RootfsB
mtd write RootfsB 0x88000000 <len>
mtd read RootfsB 0x88000000 <len>
crc32 0x88000000 <len>

# 3. 切 slot
fhbootflag ...
```

### 2.2 绝对不能碰的分区

| 分区 | 原因 |
| --- | --- |
| `bootloader` | 写坏 = 无法启动 U-Boot，只能上编程器 |
| `factory` | 含 `fhdata` UBI 卷（真实 MAC / PON 序列号 / 密码），丢了不可恢复 |
| `identity` | 当前全 0xFF，但如果将来写入了身份信息同样不可丢 |
| `bosacal` | 光模块校准数据 |
| `frameworka/b`、`apps` | 厂商应用，刷 PonWrt 不需要动 |

## 三、备份现状

`backup/` 下 13 个文件，236.2 MiB，已与设备 CRC 核对：

```
mtd0-bootloader-complete.bin    2,621,440
bootflag.bin                      524,288
mtd-KernelA.bin                 6,291,456
RootfsA.bin                    41,943,040
mtd-KernelB-fixed.bin           6,291,456
RootfsB.bin                    41,943,040
apps.bin                       33,554,432
rootfs_data.bin                75,497,472
frameworka.bin                 16,777,216
frameworkb.bin                 16,777,216
mtd9-factory-complete.bin       5,242,880
bosacal.bin                       131,072
identity.bin                      131,072
```

## 四、`sha256sums` 过期，不要用它校验

```
backup/fw/built/sha256sums              2026-11-06 21:50
backup/fw/built/*.itb, *.bin            2026-11-07 01:34   ← 晚了 3h44m
```

`sha256sums` 是旧构建的产物，和现在的镜像是两批东西：

```
sha256sums 记录  a2e464e9... / a7cd9627...
实际镜像         b5587e61... / 0f50f40b...
```

`config.buildinfo`、`feeds.buildinfo`、`.manifest`、`version.buildinfo` **都对得上**
（它们的生成时间早于镜像重打包，内容未变）。

### 真实哈希（以此为准）

```
initramfs-uImage.itb      b5587e613b9deba2041956e8cebf343768c5d7b1199debcf3f470cdc0288100f
squashfs-sysupgrade.bin   0f50f40b9ea91abc462f4e2c309f74a061485a24397c45e453d69cc99ed92b2a
```

## 五、正确的修法（代码层面）

要让 `sysupgrade` 在 HG5580A 上可用，需要给 `platform.sh` 加分支：

```sh
platform_check_image() {
	local board=$(board_name)
	case "$board" in
	fiberhome,hg5580a)
		# 校验 FIT
		fit_check_image "$1" || return 1
		return 0
		;;
	...
}

platform_do_upgrade() {
	local board=$(board_name)
	case "$board" in
	fiberhome,hg5580a)
		# 切到非当前 slot，写裸分区，然后改 bootflag
		hg5580a_do_upgrade "$1"
		;;
	...
}
```

这需要新增一个 `hg5580a_do_upgrade()` 实现：
1. 读 `bootflag` 判断当前在 A 还是 B
2. 写入**另一个** slot（保证当前系统仍可启动）
3. 校验 CRC
4. 写 `bootflag` 指向新 slot
5. 若启动失败，可从原 slot 恢复

**在实现并验证之前，只能用 U-Boot 手工刷机。**

## 六、`airoha-paged-bosa` 在 manifest 里的名字

搜 `airoha-paged-bosa` 在 `.manifest` 里找不到，因为它是 kmod 内部的模块名：

```
kmod-airoha-pon-frontend - 6.18.55-r12      ← 这才是包名
```

设备上实测加载成功：

```
airoha-paged-bosa 0-0051: UX3363 frontend registered, ID 55583333363331
```

**不是缺失，无需处理。**
