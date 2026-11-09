# HG5580A 开发状态（交接笔记）

> 最后更新：2026-11-10 04:15 +08:00
> 分支 `Ponwrt-5380A`，HEAD `312aecc`

这份文件记录「现在处在哪一步、下一步做什么、证据在哪」，便于隔一段时间回来
继续。所有结论都标注了验证方式，没有推测。

---

## 一、当前设备状态

**U-Boot 2026.07 跑在内存里，flash 未写入。**

```
model   : FiberHome HG5580A
version : U-Boot 2026.07 (Nov 10 2026 - 02:46:47 +0800)
ram     : 512 MiB
flash   : 256 MiB (SkyHigh ML02G300WH100 / S35ML02G300)
ubi     : true
rebuild : true
```

安全性：`bootloader` 分区一个字节都没动。**断电重启会回到原厂 U-Boot，
原厂系统仍能正常启动。**

判断依据：
```sh
# 串口 log 里有
spi_nand nand@0: SkyHigh SPI NAND was found.
spi-nand: 256 MiB, block size: 128 KiB, page size: 2048, OOB size: 128
HTTP management: http://192.168.0.1/  (DHCP enabled)

# API 返回
GET /api/device -> {"model":"FiberHome HG5580A","flash_bytes":268435456,...}
```

---

## 二、flash 实际布局（已实测确认）

`mtd list` 报的是**原厂 10 分区**，不是早期设计稿里的 14 分区：

```
0x00000000  0x280000   bootloader    只读，原厂 BL2+FIP
0x00280000  0x080000   bootflag      只读，原厂 A/B 选择器
0x00300000  0x600000   KernelA       只读，原厂系统槽 A
0x00900000  0x2800000  RootfsA       只读，原厂系统槽 A
0x03100000  0x600000   KernelB
0x03700000  0x2800000  RootfsB
0x05f00000  0x6800000  apps      ★   UBI 104 MiB
0x0c700000  0x1000000  frameworka    只读
0x0d700000  0x1000000  frameworkb    只读
0x0e700000  0x500000   factory   ★★  永不写入
```

**为什么坚持保留原厂分区表：** `factory` 存 MAC 地址、PON 序列号、光模块校准，
是这台机器上唯一不可恢复的数据。把它排除在任何 U-Boot 写入范围之外，意味着
即使刷机失败也不会丢设备身份。

UBI 卷（全部在 `apps` 内）：

```
fip          静态     BL31 + U-Boot（待写入）
fit          动态     系统固件（待写入）
rootfs_data  动态     可写 overlay（安装时自动创建）
ubootenv     124 KiB  U-Boot 环境
ubootenv2    124 KiB  双份，掉电安全
bosa         372 KiB  UX3363 校准
ri           372 KiB  板级身份
```

重建 UBI 的实测输出：

```
Creating dynamic volume bosa of size 262144
Creating dynamic volume ri of size 262144
UBI rebuilt with empty base volumes.
```

---

## 三、备份（已完成，这是最重要的资产）

位置：`H:\Deepseek\hg5580a-port\backup\uboot-web\`

| 分区 | 大小 | md5 |
| --- | --- | --- |
| **factory** | 5,242,880 | `cd983ec4be8e524a54ee33aa7db524d1` |
| **bootloader** | 2,621,440 | `e637d4fc6d5cc544536e4b0371dee589` |
| **bootflag** | 524,288 | `c5f86473c8a97aae86c3bfbd89b0a865` |
| KernelA | 6,291,456 | `04b0108f11ff1ae14cb26fd31b30d54c` |
| RootfsA | 41,943,040 | `a00605350b4131ed7b0e6f28a416df1c` |
| KernelB | 6,291,456 | `816636694375509fca131677f2a57916` |
| RootfsB | 41,943,040 | `bab0be9bd384d2167bdcb6975510f12d` |
| frameworka | 16,777,216 | `f22a5b1a378802629f48b569008c7c14` |
| frameworkb | 16,777,216 | `f22a5b1a378802629f48b569008c7c14` |

`factory` 头部是 `55 42 49 23`（`UBI#`），确认是 UBI 容器。

**恢复 factory 的方法**（万一需要）：
```powershell
.\tools\backup-via-web.ps1              # 先确认脚本能跑
# 或 Web 页面 Advanced -> Write partition -> factory
```

---

## 四、云编译

workflow：`.github/workflows/build-hg5580a-ubi.yml`，25 步。

**最近一次运行：**
```
run 42690146857   Build HG5580A UBI + U-Boot   312aecc
https://github.com/Li-tian-suo/ponwrt-hg5380a/actions/runs/42690146857
```

**历史结果（重要，说明修复是否有效）：**

| commit | 结果 | 说明 |
| --- | --- | --- |
| `5f79760` | `Configure` 失败 | `fitblk=m`，HIDDEN 包没进镜像 |
| `da1f843` | `Configure` **通过** | fitblk 修复生效，卡在 `Download sources` 后被新提交取消 |
| `75465d5` | `Configure` + `Download sources` 通过 | 被新提交取消（concurrency） |
| `312aecc` | 进行中 | 加了五份 DTS 校验 |

**产物（本地已编译验证过的版本）：**
```
ponwrt-airoha-an7583-fiberhome_hg5580a-ubi-squashfs-sysupgrade.itb   34,169,102 B
ponwrt-airoha-an7583-fiberhome_hg5580a-ubi-initramfs-recovery.itb    29,884,416 B
an7583-fiberhome-hg5580a-preloader.bin                                  117,760 B
an7583-fiberhome-hg5580a-bl31-u-boot.fip                                370,688 B
```

---

## 五、修掉的问题（每条都有根因）

### 1. `fitblk` 是 HIDDEN 包

```
package/utils/fitblk/Makefile:  HIDDEN:=1
                                default y if DEFAULT_fitblk
```
没有任何 profile 设 `DEFAULT_fitblk`，所以它永远不被自动选中。

`DEVICE_PACKAGES += fitblk` 不够，必须：
```
CONFIG_PACKAGE_fitblk=y      # 显式
# 且 defconfig 会把它改回 =m，必须 defconfig 之后再 sed 一次
sed -i 's/^CONFIG_PACKAGE_fitblk=m$/CONFIG_PACKAGE_fitblk=y/' .config
```

为什么必须 `=y`：UBI 镜像启动时要把 FIT 里的 rootfs 释放成块设备，模块形式
不在 rootfs 里，启动时根本加载不到。

### 2. DTS 分区表与实际不符

三份文件写了三种布局：

| 位置 | 分区数 | apps 之后 |
| --- | --- | --- |
| `board/` 旧版 | 13 | `apps` 32 MiB + `rootfs_data` 72 MiB |
| `target/linux/` 旧版 | 14 | `apps` 32 MiB + `overlay` 24 MiB + `apps_data` 48 MiB |
| **实机** | **10** | `apps` 104 MiB，无 overlay/apps_data |

U-Boot DTS 早期写 `bl2` + `ubi` 两分区，结果 U-Boot 找不到 `ubi` 分区，
回退去 attach mtd2（KernelA），日志是 `cannot attach mtd2`。改成原厂布局后
正确指向 mtd7。

**处理方式：拆成 common + 两套 parts**（不能简单 `/delete-node/` 覆盖，因为
基础文件在 `&spi_nand/partitions` 里定义了 `bosa_calibration` / `fh_base_mac`
等 5 个 label，覆盖时重定义会触发 dtc 的 duplicate-label 检查）：

```
an7583-fiberhome-hg5580a-common.dtsi        全部硬件节点，无分区表
an758x-fiberhome-hg5580a-stock-parts.dtsi   原厂 14 分区
an758x-fiberhome-hg5580a-ubi-parts.dtsi     10 分区 + UBI 卷
an7583-fiberhome-hg5580a.dts                common + stock
an7583-fiberhome-hg5580a-ubi.dts            common + ubi
```

### 3. `bootargs-append` 被静默覆盖

平台 dtsi 已有 `bootargs-append`，而我在变体里也用 `bootargs-append`。dtc
按节点合并属性，结果**平台那个赢了**，UBI 镜像最终带着原厂 cmdline：

```
root=/dev/mtdblock5 rootfstype=squashfs fstools_overlay_name=overlay
```

这指向 UBI 布局根本不存在的分区。

**修法：单一写入者。** common 完全不写 bootargs，每个变体写完整字符串。

最终：

```
stock: console=ttyS0,115200 earlycon swiotlb=noforce rootwait
       root=/dev/mtdblock5 rootfstype=squashfs
       fstools_overlay_name=overlay ubi.fm_autoconvert=1

ubi:   console=ttyS0,115200 earlycon swiotlb=noforce rootwait
       ubi.block=0,fit ubi.fm_autoconvert=1
       + rootdisk = <&ubi_fit>
```

### 4. 链式验签

TF-A `make_helpers/defaults.mk:254` 无条件 `TRUSTED_BOARD_BOOT := 1`，
BL2 走 `load_auth_image()` 要求完整信任链。原厂 FIP 带 6 张证书，我们的一张也没有。

TF-A 自带逃生门：
```c
if (dyn_is_auth_disabled() == 0)
        return load_auth_image_recursive(...);
return load_image(...);
```
但 ecnt 平台**从不填充 fconf TBBR**，`disable_auth` 永远是 0，从设备树走不到。

补丁直接在 `bl2_main.c` 里调 `dyn_disable_auth()`。**关键的第二半**：
`TCSUPPORT_*` 变量不会自动变成 `-D`，必须在 `tf-a/Makefile` 里 `add_define`
注册，否则 `#if` 恒假、代码被预处理器删掉——这是第一次尝试失败的真实原因。

验证（反汇编）：
```
81000e80  bl  auth_mod_init
81000e84  bl  dyn_disable_auth     ← 必须出现
81000e8c  bl  bl2_load_images
```
cloud build 里有同名断言，不出现直接失败。

### 5. 只改 `httpd-page.html` 不会触发重建

`httpd_page.c` 由 bin2c 生成、在 build 树里。必须删掉
`httpd_page.c` / `httpd_page.o` / `.httpd_page.c.cmd` 再 make，
否则拿到的还是旧页面。

### 6. 三个 dtc 陷阱

```
&chosen 找不到        -> chosen 节点没有 label，加 fh_chosen 标签
多行字符串拼接非法    -> dtc 不做 C 相邻字面量拼接，必须单行
bootargs 被覆盖       -> 见上面第 3 条
```

---

## 六、网页备份的真相

**原有功能是好的，我之前判断错了。**

服务端 `net/lwip/httpd.c` 的 `fs_close_custom()`：

```c
downloads--;
if (!complete || offset + size >= backup_request.size) {
        backup_ready = false;
        phase = complete ? "done" : "error";
} else {
        backup_at = get_timer(0);     /* 中间段重置 30 秒窗口 */
}
```

设计就是「一次 backup 任务 + 连续多次分段下载」，中间段自动续期，最后一段
关闭会话。

实机验证：KernelA 6 MiB 两段连续下载，完整拿到 6,291,456 字节。

早先失败的原因是我的脚本**每段重新建任务**，导致 `downloads` 计数重叠返回 409。

**下载 URL 格式**（这是真正容易搞错的地方）：
```
GET /api/download/<task_id>/<offset>/<length>     斜杠分隔
```
不是 `?offset=&length=`。`open_download()` 解析：
```c
id = simple_strtoul(name, &end, 10);
if (*end != '/') return 400 "invalid range";
offset = simple_strtoull(end + 1, &end, 10);
if (*end != '/') return 400 "invalid range";
```
所以查询字符串形式会在第二个 `/` 检查处失败。

**已加的增强**（`uboot-port/patches/web-backup.diff`）：

```
Download all 按钮   按优先级批量：factory -> bootloader -> bootflag
                    -> bosa -> ri -> KernelA/B -> RootfsA/B -> frameworka/b
                    服务器暴露但列表里没有的自动追加到末尾
每文件 MD5          浏览器原生只有 SHA-256，内联了一份 MD5
双击结果区          导出 backup.md5
```

`factory` 排第一是刻意的：中途失败也已经拿到最不能丢的文件。

MD5 实现验证方式（`tools/test-inline-md5.py`，本机没有 Node.js）：
- 静态检查：init state 四个值、`0x80` 填充、`nblk*16-2` 长度字位置、
  `add32(a,b){return (a+b)|0}` 惯用法、rotate 惯用法 `(a<<s)|(a>>>(32-s))`
- 从 JS 精确提取 64 组 `(shift, constant)` 对
- 用 Python 按同样循环结构复现，与 `hashlib.md5` 对比 10 个用例：
  空串 / `a` / `abc` / 55 / 56 / 63 / 64 / 65 字节（覆盖每个填充边界）/
  1000 字节 / 4 MiB —— 全部匹配

---

## 七、下一步（按顺序）

### 1. 看云编译结果
```powershell
# 或者直接开浏览器
https://github.com/Li-tian-suo/ponwrt-hg5380a/actions
```
关注 `312aecc` 的 `Apply board files`（五份 DTS 校验）和 `Configure`。

### 2. 写入引导与系统（只在云编译通过后做）

U-Boot Web → `http://192.168.0.1/`：

```
1. Rebuild UBI          格式化 apps，建 fip/ubootenv/bosa/ri
2. Flash U-Boot         写 .fip 到 UBI fip 卷
3. Install system       写 .itb 到 UBI fit 卷
4. Boot system
```

**BL2 最后刷**，它替换 `bootloader` 分区，是唯一可能需要 XMODEM 救援的步骤。

### 3. 光测速
需要光纤接入。XG-PON 线路可用，GPON 不支持（`airoha-xpon-mode.c` 的 GPON
入口省略了 `.mac_supported = true`，`main.c:200` 返回 `-EOPNOTSUPP`；
PCS 支持但 MAC 不支持）。

---

## 八、救援手段

### X 模式（XMODEM）

BL2 找不到有效 FIP 时请求 XMODEM：
```
Press 'x' for XMODEM download...
```
**FIP 只进内存，不写 flash**，可无限重试。

```powershell
.\tools\xmodem-send.ps1 -Port COM4 -File <fip> -WaitForPrompt
```

反汇编证据（`bl2_load_images`）：
```
bl  bl2_do_load_images       先从 flash 读（会验签）
bl  fip_image_xmodem_load    失败后走 XMODEM
bl  bl2_do_load_images       重试
```

### 回滚原厂

```sh
# U-Boot 命令行
tftpboot 0x90000000 bootloader.bin
mtd erase bootloader
mtd write bootloader 0x90000000 0x0 0x280000
```

原厂 `bootcmd` 恢复：
```
setenv bootcmd "ldkernel;bargsenv;bootm"
saveenv
fhbootflag set 0 0 0 0
reset
```

⚠️ **不要用 `bootflag swap`**，它会翻转全部四个标志位。

---

## 九、编译环境（本机）

```sh
CROSS_COMPILE=/root/build/hg5580a/staging_dir/toolchain-aarch64_cortex-a53_gcc-14.4.0_musl/bin/aarch64-openwrt-linux-musl-
ARM32_CROSS_COMPILE=/usr/bin/arm-none-eabi-
MBEDTLS_DIR=/root/mbedtls-3.4.1          # 必须 3.4.x
BUILD_JOBS=$(nproc)
```

**mbedtls 必须是 3.4.x**：TF-A 的 `drivers/auth/mbedtls/mbedtls_common.mk:76`
硬编码引用 `library/hash_info.c`，3.6.x 删掉了这个文件。OpenWrt 的
`build_dir/.../mbedtls-*` 是 CMake 配置过的目录，用它会报
`No rule to make target '.../hash_info.c'`。

**不要跑 `make defconfig` 而不重新应用 libcronet sed**，用
`make olddefconfig` / `make prepare-tmpinfo`。

### 常用脚本

```
tools/backup-via-web.ps1        分区备份（走 Web API）
tools/xmodem-send.ps1           XMODEM 发送
tools/verify-dts.sh             独立用 dtc 编译两个 DTS 变体
tools/uboot-rebuild-page.sh     强制重建 httpd 页面
tools/check-workflow-yaml.sh    校验 workflow 结构
tools/test-inline-md5.py        验证内联 MD5
tools/refactor-dts.sh           DTS 拆分（幂等）
tools/gen-web-patch.sh          重新生成网页补丁
```

---

## 十、环境速查

```
设备串口   COM4  (CH340, USB\VID_1A86&PID_7523), 115200 8N1
PC 网卡    ifIndex 16, 192.168.1.126/24 + 192.168.0.2/24, 1 Gbps
U-Boot IP  192.168.0.1
已知现象   mii info 里 YT8821 只协商到 10baseT HDX，TFTP 约 590 KiB/s
           ——原厂 U-Boot 也是这样，不是我们的问题
```

仓库：`https://github.com/Li-tian-suo/ponwrt-hg5380a`，分支 `Ponwrt-5380A`。
