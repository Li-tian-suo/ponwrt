# HG5580A 刷机教程

> Airoha AN7583 · SkyHigh ML02G300WH100 (S35ML02G300) 256 MiB SPI-NAND
> U-Boot 2026.07 + TF-A 2.10 · PonWrt UBI 布局

本文所有步骤均在实机验证。

---

## 零、先读这一段

**这台机器上唯一不可恢复的数据是 `factory` 分区**（MAC 地址、PON 序列号、光模块校准）。
它不在 UBI 里，任何 U-Boot 操作都不会碰它——但**你在刷机前必须先备份它**。

另外要清楚分区布局：flash 保留**原厂 10 分区**，UBI 只占 `apps`（104 MiB）：

```
0x00000000  0x280000  bootloader      原厂 BL2+FIP，刷 U-Boot 会替换
0x0280000   0x80000   bootflag        原厂 A/B 选择器
0x0300000   0x600000  KernelA         原厂系统槽 A
0x0900000   0x2800000 RootfsA         原厂系统槽 A
0x3100000   0x600000  KernelB         原厂系统槽 B
0x3700000   0x2800000 RootfsB         原厂系统槽 B
0x5f00000   0x6800000 apps      ★     UBI 放这里（104 MiB）
0xc700000   0x1000000 frameworka
0xd700000   0x1000000 frameworkb
0xe700000   0x500000  factory   ★★    永不写入
```

---

## 一、准备工作

### 1.1 硬件

| 项目 | 要求 |
| --- | --- |
| 串口 | CH340 / FTDI，115200 8N1，接设备调试口 |
| 网线 | 接 **lan1**（2.5G YT8821）或 lan2~lan4（MT7530） |
| PC 网络 | 静态 `192.168.0.2/24`（U-Boot 恢复模式用） |

### 1.2 需要下载的文件

从 release 页面取：

| 文件 | 大小 | 用途 |
| --- | --- | --- |
| `an7583-fiberhome-hg5580a-preloader.bin` | 117,760 B | BL2 + FIP，写到 NAND `0x0` |
| `an7583-fiberhome-hg5580a-bl31-u-boot.fip` | 370,688 B | BL31 + U-Boot，写进 UBI `fip` 卷 |
| `ponwrt-...-hg5580a-ubi-squashfs-sysupgrade.itb` | ~34 MB | 系统固件 |
| `ponwrt-...-hg5580a-ubi-initramfs-recovery.itb` | ~30 MB | 救援用 initramfs |

校验值在 release 正文里，刷之前先 `sha256sum` 对一遍。

---

## 二、进入 U-Boot

### 2.1 方式 A：原厂 U-Boot 还在

上电，串口出现：

```
UserName:
Password:
```

输入原厂凭据（**不在此公开**），进入 `U-Boot>`。

### 2.2 方式 B：已经刷过新 U-Boot

上电后会自动出菜单：

```
U-Boot HG5580A
1. Boot system
2. Web recovery
3. Boot initramfs via TFTP
4. Flash system via TFTP
5. Flash U-Boot via TFTP
6. Flash BL2 via TFTP
7. Show storage information
8. Reboot
0. Exit
```

### 2.3 方式 C：已经在新 U-Boot 里，进 Web 恢复

选 `2. Web recovery`，或命令行 `run boot_recovery`：

```
HTTP management: http://192.168.0.1/  (DHCP enabled)
```

浏览器打开 **http://192.168.0.1/**

---

## 三、备份（必做）

### 3.1 用 Web 页面

Web → **Backup** 标签 → 选择目标 → **Download backup**

**必须备份的（按优先级）：**

1. `factory` — MAC / PON SN / 校准，**丢了不可恢复**
2. `bootloader` — 原厂 BL2+FIP，回退用
3. `bootflag` — A/B 状态
4. `bosa` / `ri` — UBI 里的板级数据卷
5. `KernelA` / `RootfsA` — 原厂系统，可回退

> **注意**：网页备份按 4 MiB 分段。功能本身正常（实测 6 MiB 两段完整），
> 但一次只处理一个目标，大分区请耐心等。

### 3.2 用脚本批量备份（推荐）

仓库自带 `tools/backup-via-web.ps1`：

```powershell
# 只备份最关键的 factory
.\tools\backup-via-web.ps1 -Only factory

# 备份全部（除整片 flash）
.\tools\backup-via-web.ps1
```

脚本会生成 `MANIFEST.txt` 记录每个分区的 md5。

**实机备份结果（参考）：**

```
factory      5,242,880  md5 cd983ec4be8e524a54ee33aa7db524d1
bootloader   2,621,440  md5 e637d4fc6d5cc544536e4b0371dee589
bootflag       524,288  md5 c5f86473c8a97aae86c3bfbd89b0a865
KernelA      6,291,456  md5 04b0108f11ff1ae14cb26fd31b30d54c
RootfsA     41,943,040  md5 a00605350b4131ed7b0e6f28a416df1c
KernelB      6,291,456  md5 816636694375509fca131677f2a57916
RootfsB     41,943,040  md5 bab0be9bd384d2167bdcb6975510f12d
frameworka  16,777,216  md5 f22a5b1a378802629f48b569008c7c14
frameworkb  16,777,216  md5 f22a5b1a378802629f48b569008c7c14
```

### 3.3 命令行备份（原厂 U-Boot）

```sh
mtd read factory 0x88000000 0x0 0x500000
# 然后靠串口传出去，或先存到能访问的地方
```

---

## 四、首次安装：三步

### 步骤 1：重建 UBI

**Web → Flash → UBI operations → Rebuild UBI**

这会格式化 `apps` 分区（104 MiB），建立：

```
fip          待写入
ubootenv   126,976 B
ubootenv2  126,976 B
bosa       380,928 B
ri         380,928 B
```

实机输出：

```
Creating dynamic volume bosa of size 262144
Creating dynamic volume ri of size 262144
UBI rebuilt with empty base volumes.
Write FIP, board data and system firmware before reboot.
```

> ⚠️ 此时 `fip` 卷是空的。**如果此时断电重启，设备会回到原厂 U-Boot**
> （因为原厂 bootloader 没动），原厂系统仍能启动。这是安全兜底。

### 步骤 2：写入 U-Boot

**Web → Flash → Flash U-Boot → 选择 `*-bl31-u-boot.fip` → Upload and write**

写入 UBI 的 `fip` 卷。

**实机验证过的重要细节**：我们的 FIP **不带证书**，所以 BL2 必须跳过验签。
如果 `bl2_main` 没有调用 `dyn_disable_auth()`，会看到：

```
ERROR:   Authentication failed
```

仓库的 `uboot-port/patch-tfa-unsigned.sh` 就是解决这个的，release 里的产物已打过补丁。

### 步骤 3：写入系统

**Web → Flash → Install system → 选择 `*-ubi-squashfs-sysupgrade.itb` → Upload and flash**

实机会写入 `fit` 卷并创建 `rootfs_data`。

然后 **Boot system**。

---

## 五、刷 BL2（最后一步，风险最高）

**只有在前面都验证通过后才做。**

**Web → Flash → Flash BL2 → 选择 `*-preloader.bin` → Upload and write**

这一步替换 `bootloader` 分区（`0x0`，2.5 MiB）。

### 刷 BL2 之前必须确认

1. ✅ `factory` 已备份且 md5 对得上
2. ✅ `bootloader` 已备份
3. ✅ 新 U-Boot 已能在 UBI 里正常启动（步骤 2、3 已通过）
4. ✅ 有 XMODEM 救援手段（见第六节）

### 为什么 BL2 和 FIP 必须配套

原厂 FIP 带 6 张证书，我们的不带。四种组合只有一种能跑：

| BL2 | FIP | 结果 |
| --- | --- | --- |
| 原厂 | 原厂 | ✅ 正常 |
| 原厂 | 我们的 | ❌ 验签失败 |
| 我们的（未打补丁） | 我们的 | ❌ 验签失败 |
| **我们的（已打补丁）** | **我们的** | ✅ 正常 |

**所以 BL2 和 FIP 必须一起换，不能只换一个。**

---

## 六、救援：X 模式（XMODEM）

**这是最关键的保命手段。** 只要 BL2 还能跑，就不怕刷坏 U-Boot。

### 6.1 原理

BL2 找不到有效 FIP 时会请求 XMODEM：

```
Press 'x' for XMODEM download...
```

**FIP 只进内存，不写 flash。** 所以可以无限次重试，不怕刷坏。

反汇编证据（`bl2_load_images`）：

```
bl  bl2_do_load_images        ← 先从 flash 读（会验签）
bl  fip_image_xmodem_load     ← 失败后走 XMODEM
bl  bl2_do_load_images        ← 重试
```

### 6.2 操作

```powershell
.\tools\xmodem-send.ps1 -Port COM4 -File <bl31-u-boot.fip> -WaitForPrompt
```

然后给设备上电，脚本会等提示、自动发送。

也可以用 SecureCRT / Tera Term 的 XMODEM 发送功能。

进去之后再用 Web 页面正常写入 FIP。

---

## 七、回滚到原厂

### 7.1 只回滚系统（BL2 已是新的）

Web → Install system → 上传原厂 sysupgrade

### 7.2 完整回滚

需要原厂 `factory` / `bootloader` 备份：

```sh
# 在 U-Boot 命令行
tftpboot 0x90000000 bootloader.bin
mtd erase bootloader
mtd write bootloader 0x90000000 0x0 0x280000
```

或 Web → Advanced → **Restore entire Flash**（需要整片备份）。

### 7.3 原厂 bootflag

原厂 U-Boot 用 `bootflag` 选 A/B 槽。如果新 U-Boot 写坏了 bootflag：

```sh
bootflag read
bootflag swap
```

> ⚠️ `bootflag swap` 会翻转全部四个标志位，**不要在不确定时用**。

---

## 八、常见问题

| 现象 | 原因 | 解决 |
| --- | --- | --- |
| `Authentication failed` | BL2 有验签但 FIP 无证书 | 用打过补丁的 BL2 |
| `cannot attach mtdN` | DTS 分区表与实际不符 | 用 release 里的 DTS 重编 |
| `bad image sequence number` | UBI 头是别的实例留下的 | Rebuild UBI |
| Web 打不开 | IP 网段不对 | PC 设 192.168.0.2/24 |
| `TFTP error -1` | serverip 不对 | `setenv serverip <PC_IP>` |
| 串口无输出 | 波特率/接线 | 115200 8N1，确认 TX/RX/GND |
| 网络很慢 | YT8821 协商到 10baseT HDX | 正常现象，原厂 U-Boot 就这样 |

---

## 九、编译自己刷的固件

### 9.1 云编译（推荐）

fork 仓库 → Actions → **Build HG5580A UBI + U-Boot** → Run workflow

产物在 Actions artifact 里，包含固件和 bootloader 两部分。

### 9.2 本地编译

```sh
# 固件
cp board/an7583-fiberhome-hg5580a.dts target/linux/airoha/dts/
cat board/hg5580a-ubi.mk.snippet >> target/linux/airoha/image/an7583.mk
make menuconfig   # 选 Target: airoha/an7583, Device: FiberHome HG5580A (UBI)
make -j$(nproc)
```

```sh
# U-Boot
git clone https://github.com/pbs05/uboot-an758x && cd uboot-an758x
cp -r <repo>/uboot-port/configs/* configs/
cp -r <repo>/uboot-port/board/*   board/airoha/an7583/
cp -r <repo>/uboot-port/dts/*     arch/arm/dts/
sh <repo>/uboot-port/patch-tfa-unsigned.sh tf-a

export CROSS_COMPILE=aarch64-linux-gnu-
export ARM32_CROSS_COMPILE=arm-none-eabi-
export MBEDTLS_DIR=/opt/mbedtls-3.4.1     # 必须 3.4.x
./scripts/build-an758x.sh hg5580a
```

> **两个编译坑**：
> 1. `MBEDTLS_DIR` 必须是含 `library/hash_info.c` 的完整源码树（3.4.x），
>    3.6.x 删掉了这个文件，OpenWrt 的 build_dir 目录也不行。
> 2. `TCSUPPORT_*` 变量不会自动变成 `-D`，必须在 `tf-a/Makefile` 里
>    `add_define` 注册——这是打补丁时最容易漏的一步。

---

## 十、验证清单

刷完确认：

```sh
# 1. U-Boot 起来了
#    串口应看到 "U-Boot HG5580A" 菜单

# 2. Web 可访问
curl http://192.168.0.1/api/device
#    -> {"model":"FiberHome HG5580A","flash_bytes":268435456,...}

# 3. 分区表正确
curl http://192.168.0.1/api/storage
#    -> 应有 bootloader/bootflag/KernelA/RootfsA/KernelB/RootfsB/ubi/frameworka/frameworkb/factory

# 4. 系统启动后
cat /proc/mtd          # 10 个分区
mount | grep overlay   # overlayfs on / (UBI)
cat /proc/sys/kernel/hostname   # ponwrt
```
