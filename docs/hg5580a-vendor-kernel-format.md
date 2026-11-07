# HG5580A 厂商内核包装格式（逆向完成）

> 本文记录 FiberHome / ATOS 厂商 U-Boot `ldkernel` 要求的内核镜像格式。
> **这是刷机失败的根因**：PonWrt 的 FIT 不能直接写进 KernelA/KernelB。

## 一、厂商格式

```
文件偏移            内容
0x0000 .. 0x2100    私有头（8448 B）
    0x0000          magic: 01 00 64 aa 78 56 34 12
    0x0010          UUID
    0x0040          X.509 证书段（"Trusted Key Certificate"）
    0x0098          u32 LE：对齐补值
    0x00A0          u32 LE：payload 结束偏移
    0x2000          "HDR2"
    0x2008          u32 LE：0x5af100（= 0xA0 的值）
    0x2010          版本串 "7.4.0.150_v006"

0x2100 .. 0x3100    FIT 元数据 FDT（totalsize 字段声明为 0x1000）

0x3100 起           payload 区
                   实际偏移 = 0x3100 + data-offset
```

### 关键公式

```
total_size = *(u32)(img + 0xA0) + *(u32)(img + 0x98)
payload    = img + 0x2100 + FIT_totalsize + data-offset
              = img + 0x3100 + data-offset
```

**`FIT_totalsize` 必须是 `0x1000`**，不是 FIT 自身的实际长度。
厂商预留了 0x1000 字节区域，U-Boot 用这个声明值定位 payload。
这是第一次刷机失败的直接原因之一。

### KernelA 实测值（设备能正常启动）

```
FIT totalsize   = 0x1000
fdt-1           data-offset 0x000000  ->  文件 0x3100   size 15,704
kernel          data-offset 0x004000  ->  文件 0x7100   size 5,932,813  lzma
                sha1 5263cf968bd943bdfbb1096664662e87bbc13da1  ✅ 实测匹配
                lzma 解压 = 19,952,128 B
rootfs_env      data-offset 0x5ad000  ->  文件 0x5b0100   size 315
                ↑ 0x5b0100 = *(u32)(0xA0) + 0x2000 ... 实际 0xA0 = 0x5af100
0x98 = 0x2000，0xA0 = 0x5af100
total_size = 0x5af100 + 0x2000 = 0x5b1100   ← 与 U-Boot 打印一致
```

## 二、决定性验证

`reproduce-vendor-kernelA.py` 用解析出的字段重新拼装 KernelA：

```
rebuilt 6,291,456 B vs original 6,291,456 B
IDENTICAL - every header field was read correctly
```

**逐字节一致**，证明格式理解完全正确。

另外确认：私有头里**不包含** payload 的 sha1/sha256/md5，
改内容不会破坏头里的一致性。

## 三、PonWrt 镜像怎么套进去

`build-kernelB-vendor.py` 的做法：

```
1. 保留厂商私有头 0x0000..0x2100 原样
2. 重建 FIT 元数据，totalsize 声明 0x1000
   fdt-1     data-offset 0x000000
   kernel-1  data-offset 0x5000（4 KiB 对齐）
   带 hash-1 = sha1(内核)
3. payload = 我们的 DT + 内核
4. 写 length 字段：0x98 = 对齐补值，0xA0 = payload 结束偏移
```

### 用哪个内核

**必须用 sysupgrade 的内核，不能用 initramfs 的**：

| 来源 | 内核大小 | 能否放进 KernelX (6 MiB) |
| --- | --- | --- |
| `initramfs.itb` | 10,775,234 B | ❌ 太大 |
| `...-sysupgrade.bin` | 5,905,664 B | ✅ 可以 |

### 生成结果

```
kernel        5,905,664 B (gzip, load=entry=0x80200000)
device tree   19,043 B
FIT 元数据    857 B 内容，声明 totalsize=0x1000
payload base  0x3100
fdt-1         文件 0x3100
kernel-1      文件 0x8100  ..  0x5a9e00
0x98 = 0x200, 0xA0 = 0x5a9e00
total_size = 0x5aa000
镜像大小   6,291,456 B（正好填满 KernelX）
crc32      0x455f3680
```

## 四、验证方法

`verify-kernelB-vendor.py` 按 ldkernel 的逻辑逐步重放：

```
1. total_size = *(u32)(0xA0) + *(u32)(0x98)         覆盖所有非零字节
2. FIT 元数据在 0x2100，totalsize=0x1000，payload base=0x3100
3. 每个子镜像：payload = 0x3100 + data-offset
4. 校验 sha1
5. 解压内核证明不损坏
6. FIT 区填充全零
```

当前输出：

```
RESULT: PASS - safe to flash
```

## 五、仍需上机确认的未知数

1. **X.509 签名是否被校验** —— 私有头原样保留，但内容变了。
   如果 U-Boot 校验签名会失败。这是可逆的：A 槽不动，随时切回。
2. **`rootfs_env` 是否需要** —— 厂商用它传给 dm-verity（`dm-mod.create`）。
   PonWrt 用裸 squashfs，不需要，所以我把它删了。
3. **启动参数从哪来** —— 厂商内核 cmdline 由 U-Boot 的 `bargsenv` 生成，
   里面有 `root=/dev/dm-0` 和 `dm-mod.waitfor="PARTLABEL=RootfsA"`。
   PonWrt 的 FIT 自带 bootargs，但 U-Boot 的 `bargsenv` 可能覆盖它。

## 六、当前设备状态

```
A 槽：厂商固件完整可用，正常启动
B 槽：上次刷入的是裸 FIT（错误格式），已确认无法启动
bootflag：0（指向 A）
```

恢复 A 槽的方法（已验证可行）：在 U-Boot 里执行 `boot`，
U-Boot 会重读 bootflag 并启动 KernelA。

要重试刷机，先用 `build-kernelB-vendor.py` 生成正确的 KernelB，
再用 `verify-kernelB-vendor.py` 确认 PASS，然后才写 flash。
