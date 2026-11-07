# HG5580A 刷机结论：签名校验挡住，只能走 bootm

> 2026-11-08 实测结论。上一版文档（`hg5580a-flash-plan.md`）里
> “三个未知数”已全部有答案，其中第三个是坏消息。

## 一、三个未知数的答案

| # | 未知数 | 答案 | 证据 |
| --- | --- | --- | --- |
| 1 | 私有头格式对不对 | ✅ 对 | `ldkernel` 打印 `Read FIT image total_size=5aa100`，与我们写入的值一致 |
| 2 | `data-position` 还是 `data-offset` | ✅ `data-offset` | 厂商 FIT 字符串表里只有 `data-offset`，根本没有 `data-position` |
| 3 | X.509 签名是否校验 | ❌ **校验，且会卡死** | 见下 |

## 二、`ldkernel` 加载的三段是什么

私有头 0x00..0x2100 里内嵌了一个 `(offset, length)` 表，
`ldkernel` 会把这三段依次搬到 `0x80045000`：

```
@0x20 off=0x0400 len=0x0a0e  ->  "Trusted Key Certificate"               2,574 B
@0x48 off=0x1000 len=0x07ea  ->  "Non-Trusted Firmware Key Certificate"  2,026 B
@0x78 off=0x1800 len=0x0682  ->  "Non-Trusted Firmware Content Certificate" 1,666 B
@0x98 off=0x2000 len via 0xa0  用于 total_size
```

（`@0x78` 的 off/len 读法略有偏移，实际长度取自 0x80）

三段都是 ASN.1/DER 格式的 X.509 证书（首字节 `0x30`）。

**关键**：我们的镜像里这三段与厂商原版**逐字节相同**：

```
厂商 id 7/11/15 sha256: c43f845a… / 531cc83e… / 4db77e85…
我们 id 7/11/15 sha256: c43f845a… / 531cc83e… / 4db77e85…
```

## 三、卡死点

A 槽（厂商镜像）正常走完：

```
Read FIT image total_size=5b1100
INFO: Loading image id=7  at 0x80045000
INFO:    Image id=7  loaded: 0x80045000 - 0x80045a0e
INFO: Loading image id=11 at 0x80045000
INFO:    Image id=11 loaded: 0x80045000 - 0x800457ea
INFO: Loading image id=15 at 0x80045000
INFO:    Image id=15 loaded: 0x80045000 - 0x80045682
kernel_off data = 000000008180017c readl = 0x00400000
kernel_off data = 000000008180016c readl = 0xbc865a00
## Loading kernel from FIT Image at 81800000 ...
```

B 槽（我们的镜像）停在 id=11 之��：

```
Read FIT image total_size=5aa100
INFO: Loading image id=7  at 0x80045000
INFO:    Image id=7  loaded: 0x80045000 - 0x80045a0e
INFO: Loading image id=11 at 0x80045000
（无后续输出，设备死机）
```

id=11 是 **"Non-Trusted Firmware Key Certificate"**。
它提供公钥，`ldkernel` 用它验证固件内容签名（id=15 是 Content Certificate，
里面带被测内容的摘要）。

**我们的内核内容与原厂不同，签名必然不匹配**，于是卡死。

## 四、结论

```
厂商 bootcmd = ldkernel ; bargsenv ; bootm
                ↑ 这里做签名校验，过不去
```

**用 `ldkernel` 这条路彻底走不通**：没有 FiberHome 的私钥，无法为 PonWrt 内核签名。

私有头格式我们已经完全掌握（能逐字节重建 KernelA），
但格式正确 ≠ 能通过校验。

## 五、唯一可行的替代路线：绕过 ldkernel，直接 bootm

`bootm` 本身**不做厂商签名校验**（它只校验 FIT 内部自带的 hash，
而那个 hash 是我们自己生成的，自然对得上）。

之前已验证可行：

```
tftpboot 0x88000000 initramfs.itb
setenv bootargs console=ttyS0,115200 earlycon swiotlb=noforce
bootm 0x88000000
```

→ PonWrt 完整启动（`Machine model: FiberHome HG5580A`，13 个 MTD 分区正常）。

### 从 initramfs 改成挂载 RootfsB

initramfs 是内存运行，掉电即失。要持久化，需要让它挂真实的 RootfsB：

```
tftpboot 0x88000000 <sysupgrade 的 FIT>        # 内核 + DT，不含 rootfs
setenv bootargs 'console=ttyS0,115200 earlycon swiotlb=noforce root=/dev/mtdblock5 rootfstype=squashfs rootwait'
bootm 0x88000000
```

- `mtdblock5` = **RootfsB**（厂商分区表与 PonWrt DTS 一致）
- RootfsB 已刷入完整 squashfs（7,051,630 B，含全部驱动包，CRC 校验通过）
- 内核能看到 MTD 分区表（已在 initramfs 里验证过 13 个分区）

### 这条路的前提条件

1. **每次开机都要手工 tftpboot + bootm**，因为 `bootcmd` 会走 `ldkernel`
   并卡在签名校验
2. 或者改 U-Boot 环境变量，让 `bootcmd` 直接 `bootm` 一个固定的内存地址
   —— 但那样内存里必须预先有镜像，掉电就没，所以仍需 TFTP

**这意味着：在不动 `bootloader` 分区（不改 U-Boot）的前提下，
HG5580A 无法脱离 TFTP 独立启动 PonWrt。**

## 六、要真正持久化，只剩两条路

### 路 A：改 U-Boot（风险高，不可逆）

让 `bootcmd` 变成：

```
mtd read KernelB 0x88000000 0x0 0x600000; bootm 0x88000000
```

即从 KernelB 分区直接读裸 FIT 到内存再 `bootm`，跳过 `ldkernel`。

- **优点**：一劳永逸，之后正常刷机就能用
- **风险**：需要写 `bootloader` 分区（2.5 MB）。写坏就只能上编程器
- **备份完整**：`backup/mtd0-bootloader-complete.bin`（2,621,440 B，CRC 已验证）

具体做法是改 U-Boot 环境变量 `bootcmd`（用 `setenv` + `saveenv`），
**不需要重写 U-Boot 二进制**，风险比想象的小——`saveenv` 只改环境区。

### 路 B：接受每次 TFTP 启动

不碰 bootloader，每次调试时手工 tftpboot。

## 七、当前设备状态

```
A 槽   厂商固件完整可用
B 槽   mtd-kernel.bin + mtd-rootfs.bin 已刷入，CRC 均已回读校验
       但走 ldkernel 会被签名校验卡死，走 bootm 可用
flag   需要 set 0 0 0 0 才能正常启动 A 槽
```

**恢复 A 槽的命令**（已验证）：

```
fhbootflag set 0 0 0 0
```

注意不要用 `bootflag swap`——它会把四个 flag 全部翻转（0→1），
把设备指向卡死的 B 槽。
