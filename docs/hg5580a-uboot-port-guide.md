# HG5580A U-Boot 移植与刷机指南

> Airoha AN7583 + S35ML02G3 SPI-NAND 256 MiB
> 基于 [pbs05/uboot-an758x](https://github.com/pbs05/uboot-an758x)，U-Boot 2026.07 + TF-A

## 一、为什么换 U-Boot

原厂 U-Boot 有三个硬伤，全部在本次移植中解决：

| 原厂问题 | 现象 | 换 U-Boot 后 |
| --- | --- | --- |
| `ldkernel` 强制验签 | 未签名内核直接卡死 | 直接 `bootm`，无验签 |
| 只跑 100baseT | YT8821 只能 100 Mbps，TFTP 极慢 | 完整 PHY 驱动，2.5G |
| 无救援手段 | 一次刷错就变砖 | **Web 页面 + XMODEM 双保险** |
| JFFS2 不可用 | OOB ECC `error -74` | U-Boot 直接管 UBI，不依赖 JFFS2 |

## 二、产物说明

| 文件 | 大小 | 用途 |
| --- | --- | --- |
| `an7583-fiberhome-hg5580a-preloader.bin` | 117,760 B | BL2，写入 NAND `0x0` |
| `an7583-fiberhome-hg5580a-bl31-u-boot.fip` | 370,688 B | BL31 + U-Boot，XMODEM / Web 送入 |
| `u-boot.bin` | 890,024 B | 纯 U-Boot，调试用 |
| `u-boot.dtb` | 14,304 B | 设备树，调试用 |

校验值（打上关闭验签补丁后的最终产物）：

```
95aeb9a1d9fd54ffcd3d77a47f316d63  an7583-fiberhome-hg5580a-preloader.bin
7c3a8751f9e907260ad307ba49fad1b0  an7583-fiberhome-hg5580a-bl31-u-boot.fip
1e767bc492197efe48f8e4d5b05a63e7  bl2.bin
b45cca358745669a89c70290f32c7964  u-boot.bin
```

FIP 内部构成（`fiptool info` 实测）：

```
EL3 Runtime Firmware BL31:  offset=0x400   size=0xD621
Non-Trusted Firmware BL33:  offset=0xDC00  size=0x4CBCB   ← U-Boot
```

**未签名**（`FIP signing skipped (key environment unset)`）。

## 二之补充、与原厂 BL2 的兼容性（重要）

**默认构建的 BL2 不兼容原厂 FIP，也不兼容自己的未签名 FIP。** 原因是
`tf-a/make_helpers/defaults.mk:254` 无条件设置 `TRUSTED_BOARD_BOOT := 1`，
BL2 会走 `load_auth_image()` 要求完整信任链。实测对比：

```
原厂 FIP（从 bootloader 备份 0x800 处提取，fiptool info）：
  BL2 / BL31 / BL33
  + trusted-key-cert / soc-fw-key-cert / nt-fw-key-cert
  + tb-fw-cert / soc-fw-cert / nt-fw-cert        ← 6 张证书，完整签名

本项目的 FIP：
  BL31 / BL33                                     ← 0 张证书
```

四种组合：

| BL2 | FIP | 结果 |
| --- | --- | --- |
| 原厂 | 原厂 | ✅ 正常工作 |
| 原厂 | 本项目 | ❌ 缺 6 张证书，验签失败 |
| 本项目（未打补丁） | 本项目 | ❌ 同样验签失败 |
| 本项目（**打补丁**） | 本项目 | ✅ 见下 |

修复方式：打两处补丁让 BL2 在运行时跳过验签，详见
[hg5580a-uboot-disable-auth.md](hg5580a-uboot-disable-auth.md)。
仓库里附了可直接执行的脚本：

```sh
sh uboot-port/patch-tfa-unsigned.sh <tf-a 源码树>
```

打完后反汇编可确认调用真的进去了：

```
$ arm-none-eabi-objdump -d bl2.elf | grep -A12 '<bl2_main>:'
  81000e7c  bl  crypto_mod_init
  81000e80  bl  auth_mod_init
  81000e84  bl  dyn_disable_auth     ← 生效
  81000e8c  bl  bl2_load_images
```

## 三、x 模式救援（XMODEM）

这是最安全的入口，**只要 BL2 还能跑，就不怕刷坏 U-Boot**。

### 3.1 前提

NAND 开头有一个能工作的 BL2。如果你已经刷过 `preloader.bin`，BL2 就在；如果还是原厂 BL2，需要先刷。

### 3.2 操作步骤

1. **接串口**：COM4（CH340），`115200 8N1`
2. **断开网线**，让 BL2 走 XMODEM 分支
3. **上电**，串口会打印：

```
NOTICE:  BL2: v2.x(release):...
NOTICE:  BL2: Built : ...
INFO:    BL2: Doing platform setup
...
```

4. BL2 请求 FIP 时，**立即按 `x`**：

```
NOTICE:  Booting Trusted Firmware
NOTICE:  BL2: Loading image id 3
Press 'x' for XMODEM download...
```

5. 用支持 XMODEM 的终端发送 FIP：
   - **SecureCRT**：`Transfer → Send Xmodem` → 选 `*-bl31-u-boot.fip`
   - **Tera Term**：`File → Transfer → XMODEM → Send`
   - **Linux**：`sx -vv an7583-fiberhome-hg5580a-bl31-u-boot.fip < /dev/ttyUSB0 > /dev/ttyUSB0`
   - **PowerShell**：用 `tools/xmodem-send.ps1`（本仓库提供）

6. 传输完成后 BL2 校验并跳转，进入 U-Boot：

```
U-Boot 2026.07 (Nov 10 2026 - 02:01:00 +0800)

CPU:   Airoha AN7583
Model: FiberHome HG5580A
DRAM:  512 MiB
spi-nand: Gigadevice SPI NAND was found.
AN7583>
```

### 3.3 x 模式的意义

**FIP 只存在于内存，不写 flash。** 所以：

- 用它可以把一台"U-Boot 刷坏了但 BL2 还在"的机器救回来
- 进入 U-Boot 后再用 Web 页面或 TFTP 正式写入 FIP
- 即使 FIP 传错了，重新上电再按 x 即可，不会变砖

## 四、Web 恢复页面

### 4.1 进入方式

U-Boot 启动后（或 x 模式进入后）：

```
AN7583> run boot_recovery
```

或者正常启动失败时自动进入（`bootcmd=run boot_ubi` 失败会 fallback）。

### 4.2 连接

- 网线插 **lan1**（2.5G，YT8821）或 **lan2~lan4**（1G，MT7530）
- PC 设静态 IP `192.168.0.2/24`
- 浏览器打开 **http://192.168.0.1/**

### 4.3 页面功能

| 按钮 | 作用 |
| --- | --- |
| **Boot system / 启动系统** | 从 UBI `fit` 卷启动 |
| **Web recovery** | 重新进入恢复模式 |
| **Install system / 刷写系统** | 上传 sysupgrade 写入 `fit` 卷 |
| **Rebuild UBI / 重建 UBI** | 重建整个 UBI（首次安装必用） |
| **Flash U-Boot** | 写入新 FIP |
| **Flash BL2** | 写入新 preloader |
| **Show storage** | 显示 MTD/UBI 信息 |
| **NAND scrub** | 强制擦除坏块（`erase.scrub=1`） |

### 4.4 首次安装顺序

```
1. Rebuild UBI / 重建 UBI          ← 建立 UBI 和卷
2. Flash U-Boot                    ← 写入 FIP 到 ubi/fip
3. 恢复板级数据卷（bosa / ri）      ← 可选，从备份恢复
4. Install system / 刷写系统        ← 上传 sysupgrade
5. Boot system / 启动系统
```

## 五、串口命令刷机（不用 Web）

U-Boot 里可以直接操作 MTD 和 UBI：

```sh
# 看分区
mtd list

# 写入 BL2（preloader 放在 0x0）
tftpboot 0x90000000 an7583-fiberhome-hg5580a-preloader.bin
mtd erase bl2
mtd write bl2 0x90000000 0 0x20000

# 写入 FIP（到 ubi/fip 卷）
tftpboot 0x90000000 an7583-fiberhome-hg5580a-bl31-u-boot.fip
ubi part ubi
ubi check fip && ubi remove fip
ubi create fip 0x100000 static
ubi write 0x90000000 fip $filesize

# 写入系统
tftpboot 0x90000000 ponwrt-...-squashfs-sysupgrade.itb
ubi part ubi
ubi check fit && ubi remove fit
ubi create fit $filesize dynamic
ubi write 0x90000000 fit $filesize

# 启动
run boot_production
```

或直接用内置环境变量：

```
run boot_tftp_write_bl2
run boot_tftp_write_fip
run boot_tftp_write_production
```

## 六、⚠️ 风险与前提

### 6.1 必须先有一份完整备份

刷 BL2 前**务必**已备份：

```sh
# 在原厂系统里
cat /proc/mtd
for p in bootloader bootflag KernelA RootfsA KernelB RootfsB apps \
         frameworka frameworkb factory bosacal identity; do
    mtd dump $p > /tmp/$p.bin
done
```

尤其 `factory`（UBI，含 MAC / PON SN / 校准数据）**丢了不可恢复**。

### 6.2 签名风险

本次产物**未签名**。如果原厂 BL2 校验 BL33 签名，会出现：

```
NOTICE:  BL2: Authentication failed
```

**解决办法**：用本项目的 preloader（同样未签名，但也不校验 BL33），即 BL2 和 FIP 一起换。

这也是为什么推荐**先刷 preloader 再刷 FIP**——两者必须配套。

### 6.3 只能动 U-Boot 相关分区

| 分区 | 能否写 | 说明 |
| --- | --- | --- |
| `bootloader` / `bl2` | ✅ 但危险 | BL2，刷错需 XMODEM 救 |
| `fip`（UBI 卷） | ✅ | BL31+U-Boot |
| `fit`（UBI 卷） | ✅ | 系统镜像 |
| `rootfs_data`（UBI 卷） | ✅ | overlay，可重建 |
| `factory` | ❌ | MAC / PON SN / 校准，**永久数据** |
| `bosacal` / `identity` | ❌ | 光模块校准 / 板级身份 |

### 6.4 与 OpenWrt 分区的关系

**换 U-Boot 后分区布局会变。** 原厂是 14 个固定 MTD 分区，新 U-Boot 是：

```
mtd0  bl2    0x0       0x20000      (128 KiB)
mtd1  ubi    0x20000   0xffe0000    (255.8 MiB)
```

UBI 内部卷：

```
fip          1 MiB static
fit          dynamic     ← 系统镜像
rootfs_data  dynamic     ← overlay
bosa         256 KiB
ri           256 KiB
```

**这意味着原来刷在 KernelB / RootfsB 的镜像不能直接用了**，必须重新打包成 UBI 格式的 sysupgrade `.itb`。

## 七、编译方法

```sh
# 依赖
sudo apt install -y build-essential gcc-aarch64-linux-gnu \
    gcc-arm-none-eabi bison flex libssl-dev device-tree-compiler \
    python3-pyelftools u-boot-tools

# mbedtls 必须 3.4.1（3.6.x 删了 TF-A 需要的 hash_info.c）
wget https://codeload.github.com/Mbed-TLS/mbedtls/tar.gz/refs/tags/mbedtls-3.4.1
tar xzf mbedtls-3.4.1.tar.gz -C /opt/mbedtls-3.4.1 --strip-components=1

# 编译
export CROSS_COMPILE=aarch64-linux-gnu-
export ARM32_CROSS_COMPILE=arm-none-eabi-
export MBEDTLS_DIR=/opt/mbedtls-3.4.1
./scripts/build-an758x.sh hg5580a
```

产物在 `output/hg5580a/`。

> 注意 `MBEDTLS_DIR` 必须指向**含 `library/hash_info.c` 的完整源码树**。
> OpenWrt 的 `build_dir/.../mbedtls-*` 虽然看起来像源码，但它经过 CMake 配置，
> 直接用会报 `No rule to make target '.../hash_info.c'`。

## 八、本次移植改动的文件

相对 `pbs05/uboot-an758x` main 分支，新增：

```
configs/an7583_fiberhome_hg5580a_defconfig          defconfig
board/airoha/an7583/an7583_fiberhome_hg5580a.env    环境变量
arch/arm/dts/an7583-fiberhome-hg5580a.dts           板级 DTS
arch/arm/dts/an7583-fiberhome-hg5580a-u-boot.dtsi   U-Boot 专用节点
scripts/build-an758x.sh                             注册 hg5580a 目标
```

SoC 层（`tf-a/plat/ecnt/an7583/`、`arch/arm/mach-airoha/an7583/`、
`drivers/net/airoha/pcs-an7583.c`）**完全复用上游，未改动**。

### 8.1 硬件参数来源

| 参数 | 值 | 来源 |
| --- | --- | --- |
| DRAM | 512 MiB @ 0x80000000 | 原厂 DTS |
| UART | `0x1fbf0000`, 115200 | 原厂 DTS + 实测 |
| SPI-NAND | S35ML02G3, 256 MiB | U-Boot 启动日志 |
| 2.5G PHY | YT8821, MDIO 0x07 | 实测 `mii info 7` |
| switch | MT7530, lan2~lan4 | 内核 DSA 绑定 |
| PON | UX3363, I2C 0x51 | `airoha-paged-bosa` 驱动日志 |
| 复位键 | GPIO 35, 低有效 | 原厂 DTS |
| 2.5G PHY 复位 | GPIO 28, 低有效 | 原厂 DTS（名字是 `an8811_reset`） |
| 2.5G TX 使能 | GPIO 15, 高有效 | 原厂 DTS |

## 九、验证状态

- [x] U-Boot 编译通过（890,024 B）
- [x] 板级标识正确（`FiberHome HG5580A` / `fiberhome,hg5580a-ubi`）
- [x] env 内嵌正确（`bootmenu_title=U-Boot HG5580A`、`httpd_ipaddr=192.168.0.1`）
- [x] Web 恢复编译进去（`CONFIG_CMD_HTTPD=y`）
- [x] SPI-NAND 驱动在（`CONFIG_MTD_SPI_NAND=y`）
- [x] 网络栈在（`CONFIG_AIROHA_ETH=y`、`CONFIG_PCS_AIROHA_AN7583=y`）
- [x] TF-A BL2 编译通过（116,146 B）
- [x] FIP 打包正确（BL31 + BL33，370,688 B）
- [x] 尺寸在窗口内（preloader 117,760 / 129,024；FIP 370,688 / 522,240）
- [ ] **实机验证**（需要物理刷机）

## 十、下一步

实机刷机建议顺序：

1. **先备份**所有 MTD 分区（尤其 `factory`）
2. 用 **x 模式**（XMODEM 送 FIP）先试跑一次 U-Boot，**不写 flash**
3. 确认串口/网络/Web 都正常后，再 `Rebuild UBI` 正式安装
4. 最后才刷 `preloader.bin` 到 `0x0`

这样任何一步出错都还能退回。
