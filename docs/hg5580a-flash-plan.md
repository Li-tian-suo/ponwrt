# HG5580A 刷机完整方案（含 bootargs 覆盖问题）

> 本文汇总刷机需要的全部条件，以及 3 个必须在小机上验证的未知数。

## 一、厂商启动链路（已完整逆向）

```
bootcmd = "ldkernel ; bargsenv ; bootm"
           ↓          ↓           ↓
     从 KernelX   拼 bootargs   启动
     读私有头     存环境变量
     解 FIT       含 dm-verity
```

### 1.1 `ldkernel` 做什么

```
1. 读 image+0xA0 和 image+0x98，算 total_size
2. 在 image+0x2100 找 FIT 元数据（totalsize 必须声明 0x1000）
3. 按 data-position / data-offset 定位子镜像
4. 处理 rootfs_env 子镜像 → 解析 dm-verity 参数：
       DATA_SIZE / HASH_TYPE / DATA_BLOCK_SIZE / HASH_BLOCK_SIZE
       DATA_BLOCKS / HASH_ALGORITHM / ROOT_HASH
5. 把内核与 DT 装进内存（日志显示 FIT 被搬到 0x81800000）
```

### 1.2 `bargsenv` 做什么

字符串表（`uboot-030000.bin` @0x9e00b 起）：

```
bargsenv                  "auto-create bootargs env"
sdram_conf   rst_gpio     vendor_name   product_name
ethaddr      snmp_sysobjid country_code  ether_gpio
power_gpio   username     password      dsl_gpio
internet_gpio multi_upgrade_gpio  onu_type  qdma_init
serdes_sel   iommu        swiotlb      iommu.passthrough
srdsIfNameAllComp  srdsPortNameAllComp  srdsEtherTypeAllComp
srdsEtherPhyTypeAllComp  srdsPortCombo
rfb_id1      rfb_id2      8811phy_addr  arht_low_power
sn_test      dm-mod.create  disable_voip  hybrid   olt_mode
```

它拼出的 cmdline 含硬编码片段：

```
0x09dd2c   "/dev/dm-0 ro rootwait"
0x09dcb1   dm-mod.waitfor="PARTLABEL=%s" dm-mod.create="
0x09dccf   dm-verity,,,ro,0 %s verity %s PARTLABEL=%s ... %s ×7
0x09de06   "bootargs len:%d more than %d ==="
```

### 1.3 为什么这会让 PonWrt 起不来

`bootm` 内部的 `fdt_chosen()`：

```c
str = env_get("bootargs");
if (str)
        fdt_setprop(blob, "/chosen", "bootargs", str, strlen(str) + 1);
```

**只要环境变量 `bootargs` 存在，就会替换设备树里的 `/chosen/bootargs`。**

实测对比：

| 来源 | root 参数 |
| --- | --- |
| PonWrt DTS 自带 | `root=/dev/mtdblock5 rootfstype=squashfs rootwait` |
| `bargsenv` 覆盖后 | `root=/dev/dm-0 ro rootwait` + dm-verity |

→ PonWrt 内核去挂 `dm-0`，那是厂商 RootfsA 的 dm-verity 映射，不是 squashfs，
挂根必然失败。

## 二、解决方案

### 2.1 改 bootcmd，跳过 bargsenv

```
setenv bootcmd 'ldkernel; bootm'
```

但必须先确认 `ldkernel` 把内核装到哪个地址、`bootm` 不带参数时是否能用它。
厂商日志显示 FIT 被搬到 `0x81800000`，且 `bootm` 无参数时默认读 `load_addr`。

**风险**：`ldkernel` 可能依赖 `bargsenv` 先设置某些环境变量才正常工作。

### 2.2 或者覆盖 bootargs 环境变量

`bargsenv` 之后、`bootm` 之前插入 `setenv`：

```
setenv bootcmd 'ldkernel; bargsenv; setenv bootargs "console=ttyS0,115200 earlycon root=/dev/mtdblock5 rootfstype=squashfs rootwait"; bootm'
```

这样 `ldkernel` 的正常流程保留（它会读 rootfs_env），只是最后把 rootfs
指回 PonWrt 的裸分区。

**这个方案更安全**，因为不改变 `ldkernel` 的行为。

### 2.3 或者让 KernelC 不带 rootfs_env

我们的 KernelB 已经删掉了 `rootfs_env`。若 `ldkernel` 找不到它会跳过
dm-verity 逻辑（代码路径未验证），此时 cmdline 里可能就没有 `root=/dev/dm-0`。

**这一点必须实测**：运行 `ldkernel` 后立刻 `printenv bootargs` 看结果。

## 三、当前的 KernelB

`build-kernelB-vendor.py` 生成，`verify-kernelB-vendor.py` 验证 PASS：

```
大小        6,291,456 B（正好填满 KernelX）
内核        5,905,664 B gzip，load/entry = 0x80200000
设备树      19,043 B
FIT         totalsize 声明 0x1000，含 hash-1 sha1
payload     0x3100 起
crc32       0x455f3680
```

已确认：厂商私有头原样保留，私有头不含 payload 校验和。

## 四、三个必须上机验证的未知数

| # | 未知数 | 验证方法 | 失败后果 |
| --- | --- | --- | --- |
| 1 | X.509 签名是否校验 | 刷 B 槽后看是否报 verify 失败 | A 槽不动，切回即可 |
| 2 | 删掉 `rootfs_env` 后 `ldkernel` 是否正常 | `ldkernel` 后 `printenv bootargs` | 无 |
| 3 | `bargsenv` 覆盖后 root 指向哪 | 同上 | 用 2.2 方案修 |

**三个都能在 U-Boot 里验证，不需要真的写 flash**：
把 KernelB 用 `tftpboot` 装到内存，手写私有头的解析过程，
或者直接临时写到 B 槽（A 槽安全）。

## 五、安全边界

- **A 槽全程不动**
- **绝不写** `bootloader` / `factory` / `identity` / `bosacal`
- B 槽写坏不影响 A 槽启动：`bootflag read` 显示 0 即指向 A
- 恢复 A 槽：U-Boot 里 `boot`（会重读 bootflag）

## 六、相关文件

| 文件 | 用途 |
| --- | --- |
| `docs/hg5580a-vendor-kernel-format.md` | 包装格式详解 |
| `docs/hg5580a-flash-tools/build-kernelB-vendor.py` | 生成 KernelB |
| `docs/hg5580a-flash-tools/verify-kernelB-vendor.py` | 验证 KernelB |
| `docs/hg5580a-flash-tools/reproduce-vendor-kernelA.py` | 重拼 KernelA 证明格式正确 |
| `backup/uboot-extract/uboot-030000.bin` | 解压出的 U-Boot 本体（848 KB） |
