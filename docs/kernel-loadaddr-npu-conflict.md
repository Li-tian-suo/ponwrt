# 内核加载地址与 NPU 预留区的冲突

> HG5580A 上 `bootm` 失败的根因、推导和修法

---

## 1. 现象

用 Web 恢复的 RAM boot 启动 initramfs：

```
Verifying Hash Integrity ... crc32+ sha1+ OK        ← 镜像完整
Booting using the fdt blob at 0x9fb16380
   Working FDT set to 9fb16380
   Uncompressing Kernel Image to 80200000
Unable to allocate memory 0x80200000 for loading OS   ← 卡在这里
```

镜像校验通过，说明不是固件损坏，而是 **U-Boot 无法在 `0x80200000` 分配内存**。

---

## 2. 镜像里确实写着 `0x80200000`

`iminfo` 的输出：

```
## Checking Image at 90000000 ...
   FIT image found
   FIT description: ARM64 OpenWrt FIT (Flattened Image Tree)
    Image 0 (kernel-1)
     Description:  ARM64 OpenWrt Linux-6.18.55
     Compression:  lzma compressed
     Data Size:    29751259 Bytes = 28.4 MiB
     Load Address: 0x80200000        ← 硬编码在 FIT 里
     Entry Point:  0x80200000
```

所以 `setenv bootm_size` 之类的运行时覆盖没用 —— FIT 里的记录才是准的。

---

## 3. `0x80200000` 为什么不可用

`bdinfo` 的 lmb 输出：

```
lmb_dump_all:
 memory.count = 0x1
  memory[0]  [0x80000000-0x9fffffff], 0x20000000 bytes, flags: none
 reserved.count = 0x7
  reserved[0]  [0x80000000-0x8003ffff], 0x40000 bytes, flags: no-map
  reserved[1]  [0x84000000-0x849fffff], 0xa00000 bytes, flags: no-map
  reserved[2]  [0x84b00000-0x84bfffff], 0x100000 bytes, flags: no-map
  reserved[3]  [0x85000000-0x869fffff], 0x1a00000 bytes, flags: no-map
  reserved[4]  [0x86b00000-0x86bfffff], 0x100000 bytes, flags: no-map
  reserved[5]  [0x86d00000-0x86dfffff], 0x100000 bytes, flags: no-map
  reserved[6]  [0x9ea89370-0x9fffffff], 0x1576c90 bytes, flags: no-overwrite
```

这些 `no-map` 区域来自 `arch/arm/dts/an7583.dtsi`：

```dts
reserved-memory {
	atf-reserved-memory@80000000 {
		no-map;
		reg = <0x0 0x80000000 0x0 0x40000>;      /* 256 KiB  */
	};

	npu-binary@84000000 {
		no-map;
		reg = <0x0 0x84000000 0x0 0xa00000>;     /* 10 MiB   */
	};

	npu-flag@84b0000 {
		no-map;
		reg = <0x0 0x84b00000 0x0 0x100000>;     /* 1 MiB    */
	};

	npu-pkt@85000000 {
		no-map;
		reg = <0x0 0x85000000 0x0 0x1a00000>;    /* 26 MiB   */
	};

	npu-phyaddr@86b00000 {
		no-map;
		reg = <0x0 0x86b00000 0x0 0x100000>;     /* 1 MiB    */
	};

	npu-rxdesc@86d00000 {
		no-map;
		reg = <0x0 0x86d00000 0x0 0x100000>;     /* 1 MiB    */
	};
};
```

NPU 窗口从 `0x84000000` 起，连续占到 `0x86e00000`，合计 **39 MiB**。

**冲突**：内核从 `0x80200000` 开始，28.4 MiB 的 lzma 载荷解压后远大于 4 MiB 的
可用空隙（`0x80200000` → `0x84000000` 只有 62 MiB，但 U-Boot 还要为解压过程留
临时空间和 FDT 位置），lmb 判定无法完成分配，直接拒绝。

---

## 4. 根因：上游默认值不适合 AN7583

```makefile
# target/linux/airoha/image/Makefile
loadaddr-$(CONFIG_TARGET_airoha_an7581) := 0x80200000
loadaddr-$(CONFIG_TARGET_airoha_an7583) := 0x80200000
loadaddr-$(CONFIG_TARGET_airoha_en7523) := 0x80200000

define Device/Default
  KERNEL_LOADADDR = $(loadaddr-y)
endef
```

平台给 AN7583 的默认值是 `0x80200000`，**但本树里每个既有的 airoha 设备都显式
覆盖了它**：

```makefile
# target/linux/airoha/image/an7581.mk
  KERNEL_LOADADDR := 0x8a000000     (多台)
  KERNEL_LOADADDR := 0x8c000000     (一台)
```

我们的 `Device/fiberhome_hg5580a-ubi` 没写，于是继承了那个不适用的默认值。

---

## 5. 修法

在设备定义里显式指定：

```makefile
define Device/fiberhome_hg5580a-ubi
  ...
  KERNEL_LOADADDR := 0x88000000
  ...
endef
```

### 为什么选 `0x88000000`

| 约束 | 值 |
| --- | --- |
| NPU 窗口结束 | `0x86e00000` |
| 内核起点 | `0x88000000` ✅ 在其之上 |
| U-Boot 自身（no-overwrite） | 从 `0x9ea89370` 起 |
| 可用空间 | `0x88000000` → `0x9ea89370` ≈ 360 MiB |

充裕，且完全避开所有保留区。

---

## 6. 验证方法

编译后检查 FIT 里的记录：

```sh
iminfo 0x90000000
# 应显示：
#   Load Address: 0x88000000
#   Entry Point:  0x88000000
```

或者直接搜二进制：

```sh
# 旧地址（应消失）
grep -c $'\x80\x20\x00\x00' image.itb
# 新地址（应存在）
grep -c $'\x88\x00\x00\x00' image.itb
```

---

## 7. 教训

**不要在 AN7583 上依赖平台默认加载地址。** 这块 SoC 的 NPU 占用了
`0x84000000`–`0x86e00000` 共 39 MiB，任何从 `0x80200000` 起的接近或超过 4 MiB
的内核都会撞上。

对照本树其它 airoha 设备（`0x8a000000` / `0x8c000000`），选 `0x88000000`
是一个安全的下界。
