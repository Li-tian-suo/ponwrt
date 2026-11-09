# HG5580A U-Boot 刷机教程

> 实测于 2026-11-08，设备：FiberHome HG5580A（Airoha AN7583）。
> 本文所有命令都在实物上跑过，包括踩到的坑。

## 零、先读这一节

**这个机型不能用 OpenWrt 默认的 sysupgrade。**
`target/linux/airoha/an7583/base-files/lib/upgrade/platform.sh` 里没有
`fiberhome,hg5580a` 分支，会落到 `nand_do_upgrade`，它要求 UBI 卷
`fip`/`ubootenv`/`ubootenv2` —— 本机这三个卷都不存在，**执行就会变砖**。

同一份分区表上 KernelA/B、RootfsA/B 都是**裸分区**，所以必须走
U-Boot 的 `mtd` 命令手工写。

---

## 一、准备

### 1.1 需要的文件

| 文件 | 大小 | 用途 |
| --- | --- | --- |
| `barefitB.bin` | 5,967,872 B | 裸 FIT，写 KernelB |
| `rootfsB.bin` | 36,255,744 B | squashfs，写 RootfsB |

由 `make` 直接产出，或从 `bin/targets/airoha/an7583/` 取：

```
mtd-kernel.bin   -> 需要转成裸 FIT（见 1.3）
mtd-rootfs.bin   -> 直接就是 rootfsB.bin
```

### 1.2 串口

```
波特率   115200 8N1
接口     本机是 CH340 -> COM4
```

**登录 U-Boot 需要账号密码**（在 `Abort` 提示时按任意键打断自动启动后出现）：

```
UserName: <账号>
Password: <密码>
```

### 1.3 生成裸 FIT

厂商 `ldkernel` 会做 X.509 固件签名校验，我们签不了名，所以绕开它、
直接用 `bootm`。`bootm` 只校验 FIT 自带的 hash（我们自己生成的）。

所以 KernelB 里要放**裸 FIT**，不是厂商包装格式：

```python
# 从 sysupgrade 镜像里截出 FIT 部分
import struct
d = open('sysupgrade.bin','rb').read()
fit_len = struct.unpack('>I', d[4:8])[0]      # FIT totalsize
PAGE = 0x800
padded = (fit_len + PAGE - 1) & ~(PAGE - 1)
open('barefitB.bin','wb').write(d[:fit_len] + b'\x00' * (padded - fit_len))
```

### 1.4 网络准备（★ 最容易踩的坑）

**U-Boot 的 YT8821 PHY 驱动只支持 100 Mbps。**

如果 PC 网卡自动协商到 2.5G/1G，`ping` 和设备 TFTP 全部不通，表现为：

```
U-Boot> ping 192.168.1.126
Using eth@1fb59000 device
（无输出，卡住）
```

而 U-Boot 里查 PHY 信息会看到：

```
U-Boot> mii info 7
PHY 0x07: OUI = 0x13D47A, Model = 0x21, Rev = 0x09, 100baseT, FDX
                                          ^^^^^^^^^^^^^^^^^^
```

**解法：把 PC 网卡强制到 100 Mbps 全双工。**

Windows：

```powershell
Set-NetAdapterAdvancedProperty -Name '以太网 4' `
  -DisplayName '连接速度和双工模式' -DisplayValue '100 Mbps 全双工'
```

改完立刻能通：

```
U-Boot> ping 192.168.1.126
host 192.168.1.126 is alive
```

**刷完后记得改回「自动侦测」，否则测速只有 100M。**

### 1.5 TFTP 服务

```powershell
python tftpd.py --root <镜像目录> --port 69
```

U-Boot 侧确认：

```
U-Boot> printenv ipaddr serverip
ipaddr=192.168.1.1
serverip=192.168.1.126
```

---

## 二、刷机步骤

### 2.1 进 U-Boot

上电后立刻连按回车打断自动启动。看到 `UserName:` 后登录。

确认提示符：

```
U-Boot>
```

### 2.2 刷 KernelB

```sh
tftpboot 0x88000000 barefitB.bin
crc32 0x88000000 0x5b1000
mtd erase KernelB
mtd write KernelB 0x88000000 0x0 0x5b1000
mtd read KernelB 0x90000000 0x0 0x5b1000
crc32 0x90000000 0x5b1000
```

**两个 crc32 必须相同**，否则不要重启。

实测输出：

```
Bytes transferred = 5967872 (5b1000 hex)
crc32 for 88000000 ... 885b0fff ==> 1fe74047
Writing 5967872 byte(s) (2914 page(s)) at offset 0x00000000
crc32 for 90000000 ... 905b0fff ==> 1fe74047      <- 一致
```

### 2.3 刷 RootfsB

```sh
tftpboot 0x88000000 rootfsB.bin
crc32 0x88000000 0x2293800
mtd erase RootfsB
mtd write RootfsB 0x88000000 0x0 0x2293800
mtd read RootfsB 0x90000000 0x0 0x2293800
crc32 0x90000000 0x2293800
```

**擦除时可能报坏块，这是正常的**：

```
[spinand_ecc_fail_check] : ECC cannot recover detected !, page=0xbd80
spi_nand_read_page: Bad Block, ECC cannot recovery detecte, page=0xbd80
Read erase block counter 0x2f6 fail.
```

`page=0xbd80` 对应物理 `0xbd80 × 0x800 = 0x5EC0000`，正好在 RootfsB
数据区**之外**（rootfs 只有 36 MB，分区 40 MiB）。写入后回读 CRC
仍然一致，说明数据没受影响。

### 2.4 配置 bootcmd

厂商 `bootcmd` 是 `ldkernel;bargsenv;bootm`，会走签名校验。改成直接 bootm：

```sh
setenv bootcmd "mtd read KernelB 0x88000000 0x0 0x600000; bootm 0x88000000"
setenv bootargs "console=ttyS0,115200 earlycon swiotlb=noforce root=/dev/mtdblock5 rootfstype=squashfs rootwait fstools_overlay_name=overlay"
saveenv
reset
```

`saveenv` 会写 SPI-NAND 的环境区，掉电不丢。

### 2.5 首次启动后必须做的两件事

刷完能进系统，但**网页打不开**。两个默认值要改：

```sh
# 1) flow_offloading 会让整个防火墙规则集加载失败
uci set firewall.@defaults[0].flow_offloading=0
uci set firewall.@defaults[0].flow_offloading_hw=0

# 2) rfc1918_filter 会让 LuCI 返回 403
uci set uhttpd.main.rfc1918_filter=0

uci commit firewall
uci commit uhttpd
/etc/init.d/firewall restart
/etc/init.d/uhttpd restart
```

原因见 `docs/hg5580a-debug-log.md` 第 4、5 条。

然后设 root 密码：

```sh
printf "admin\nadmin\n" | passwd root
```

---

## 三、验证

### 3.1 串口上确认

```
mtd: setting mtd5 (RootfsB) as root device        <- 根分区选对了
VFS: Mounted root (squashfs filesystem) readonly
jffs2: notice: complete building xattr subsystem  <- overlay 格式化成功
overlayfs:/overlay on / type overlay              <- 可写根
```

**不要出现** `Cowardly refusing to erase blocks`。

### 3.2 网页

```
http://192.168.1.1           LuCI 登录页
   用户名 root  密码 admin
http://192.168.1.1:3300      homebox 测速
http://192.168.1.1:7681      ttyd 网页终端
```

### 3.3 测速

2.5G 口是 **lan1**（YT8821 PHY），其余 lan2/3/4 是 SoC 内 PHY（1G）。

插 lan1，PC 网卡设回「自动侦测」，实测：

```
下载  2.17 Gbps   峰值 2.91 Gbps
上传  1.26 Gbps   峰值 1.32 Gbps
```

上传偏低是 homebox 用浏览器 fetch 逐块上传的固有限制，不是链路问题。

---

## 四、回滚到原厂固件

A 槽（KernelA/RootfsA）全程没动过，随时可以回去：

```sh
setenv bootcmd "ldkernel;bargsenv;bootm"
saveenv
fhbootflag set 0 0 0 0
reset
```

**不要用 `bootflag swap`** —— 它会把四个 flag 全部翻转（0→1），
把设备指向卡死的 B 槽。

`fhbootflag` 的正确语义：

```
fhbootflag set 0 0 0 0    -> 从 A 槽启动（原厂）
fhbootflag set 1 1 1 1    -> 从 B 槽启动（PonWrt）
```

---

## 五、绝对不要碰的分区

| 分区 | 内容 | 为什么不能写 |
| --- | --- | --- |
| `bootloader` | U-Boot + BL2 + BL31 | 写坏只能上编程器 |
| `factory` | UBI 卷，含 MAC / 序列号 / 光模块型号 | 唯一副本 |
| `identity` | MAC / PON 序列号 | 空则用随机 MAC |
| `bosacal` | 光模块校准 | 丢了光功率不准 |

刷机只碰 `KernelB` 和 `RootfsB`。

---

## 六、常见故障对照

| 现象 | 原因 | 解法 |
| --- | --- | --- |
| U-Boot `ping` 无响应 | YT8821 PHY 只支持 100M | PC 网卡强制 100M 全双工 |
| `Read FIT image total_size=21d36ee2` | 往 KernelB 写了裸 FIT 但走了 ldkernel | 改 bootcmd 用 bootm |
| `ldkernel` 卡死无输出 | 固件签名校验失败 | 改 bootcmd 绕过 ldkernel |
| `Cowardly refusing to erase blocks` | 分区名不是 `rootfs`，内核没选它做根 | DTS 加 `linux,rootfs` |
| 主机名变 `(none)`、密码丢失 | overlay 挂不上，退回 tmpfs | 擦 overlay 分区 |
| `LuCI 拒绝连接` | `flow_offloading` 导致规则集加载失败 | 关掉 flow_offloading |
| LuCI 403 | `rfc1918_filter` | 关掉它 |
| 所有网口同一 MAC | `identity` 分区全 0xFF | 从 factory 写入真实 MAC |
