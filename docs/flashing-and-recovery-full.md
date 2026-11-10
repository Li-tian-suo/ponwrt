# HG5580A 刷机与失败恢复完整教程

> 本文覆盖从原厂固件刷到 PonWrt 的全过程，以及**每一步失败后怎么救回来**。
> 所有地址、大小、校验值均来自实测或源码，不是推测。

---

## 0. 先读这一段

### 这台设备的特殊性

HG5580A 的启动链不是常见的「U-Boot 直接跑」：

```
Boot ROM（芯片内，不可改）
  → 从 SPI-NAND 偏移 0x800 读 FIP
  → FIP 里 UUID[0] 是 BL2，加载到 SRAM 执行
  → BL2 初始化 DRAM、NAND
  → BL2 从 UBI 的 "fip" 卷读 BL31 + U-Boot
  → BL31 跑起来，加载 U-Boot
  → U-Boot 从 UBI 的 "fit" 卷读内核
```

**关键点：BL2 不是从 flash 固定地址读 BL31，而是从 UBI 卷读。** 这决定了分区布局，
也决定了「刷错 bl2 就没救」的严重性。

### 两个不可协商的硬约束

**约束一：`ubi` 分区必须从 `0x20000` 开始**

```c
/* plat/ecnt/en7523/bl2_boot_nand_ubi.c */
#ifdef OVERRIDE_UBI_START_ADDR
#define UBI_START_ADDR      OVERRIDE_UBI_START_ADDR
#else
#define UBI_START_ADDR      0x20000          /* ← 默认值，实际用的就是这个 */
#endif
```

验证方式：反汇编 BL2 二进制，`0x20000` 作为字面量出现一次，`0x5f00000` 一次都没有。

**约束二：`bl2` 分区必须恰好一个擦除块（128 KiB）**

```c
/* net/lwip/httpd.c run_bootloader_update(true) */
if (!mtd_is_partition(mtd) || mtd->offset ||
    mtd->parent->parent || !mtd_uses_pages(mtd) ||
    mtd->size != mtd->erasesize || mtd->erasesize <= 0x800)
        goto out;
```

`mtd->size != mtd->erasesize` 直接拒绝。所以 `bl2` 只能是 `0x20000`。

### 最终布局

```
name         offset       size         end
all_flash    0x00000000   0x10000000   0x10000000
bl2          0x00000000   0x00020000   0x00020000    128 KiB
ubi          0x00020000   0x0e6e0000   0x0e700000    242 MiB
factory      0x0e700000   0x00500000   0x0ec00000    只读
bosacal      0x0ec00000   0x00020000   0x0ec20000    只读
identity     0x0ec20000   0x00020000   0x0ec40000    只读
```

`0x20000 + 0xe6e0000 = 0xe700000`，UBI 正好停在 `factory` 之前。
**`factory` / `bosacal` / `identity` 在 UBI 窗口外，`ubi-rebuild` 物理上无法触及。**

---

## 1. 刷机前必须做的备份

### 1.1 必须备份的分区

| 分区 | 大小 | 为什么重要 | 丢了会怎样 |
| --- | --- | --- | --- |
| `bootloader` | 2.5 MiB | BL2 + FIP，含安全启动证书 | **变砖**，需 JTAG |
| `factory` | 5 MiB | MAC、PON 序列号、光学校准 | 失去身份，无法注册 PON |
| `bosacal` | 128 KiB | BOSA 校准（本机实测为空白） | 可重建 |
| `identity` | 128 KiB | 身份镜像（本机实测为空白） | 可重建 |
| `apps` | 视布局 | 原厂应用数据 | 可放弃 |
| `bootflag` | 512 KiB | A/B 选择器 | 可放弃 |

### 1.2 通过 U-Boot Web 备份

用我们的 U-Boot 启动后：

```
GET http://192.168.0.1/api/storage     列出可备份目标
POST /api/task  {"operation":"backup","target":"factory"}
GET  /api/download/<id>/<offset>/<length>    分段下载，单次最多 4 MiB
```

注意下载是斜杠分段格式，不是查询参数；30 秒窗口，中间段会重置。

### 1.3 从 factory 分区提取 PON 身份

`factory` 是 UBIFS 卷 `fhdata`，解包后 `factory_conf` 里有关键字段：

```
GponSN        46485454C255B8F9      → ASCII "FHTT" + C255B8F9
GPONPassWord  48473236303132333435  → ASCII "HG26012345"
VendorCode    FH
vendor_id     ZE                    （ZTE OLT 侧厂商码）
SerialNumber  3B83524E3A2B2DDDC     设备序列号，非 PON
MAC           24:E3:A4:B2:DD:E0
transceiver_type    PLDM588-815-C10
transceiver_serial  000059BTK39007495
```

`sysinfo_conf`：

```
operators_code = CT          中国电信
operator_name  = CH_CT
area_code      = Fujian
UnifiedSoftwareVersion = V2R2.0
HardwareVersion = V1.0.0
```

---

## 2. 准备刷机载荷

需要五个文件，每个都有精确的大小要求。

### 2.1 `bl2-firstblock.bin` —— 131,072 字节

**这是最容易搞错的一步，搞错必变砖。**

`flash-bl2` 操作内部有两条路径：

```c
static bool prepare_bl2_image(u8 *image, size_t block_size,
                              const u8 *data, size_t size)
{
	if (block_size <= 0x800)
		return false;

	/* 路径 A：输入恰好一个擦除块 */
	if (size == block_size && boot_fip_valid(data + 0x800, size - 0x800, true)) {
		memcpy(image, data, size);        /* 0x0..0x800 原样保留 */
		return true;
	}

	/* 路径 B：输入是纯 FIP */
	if (size <= block_size - 0x800 && boot_fip_valid(data, size, true)) {
		memset(image, 0xff, block_size);  /* ← 0x0..0x800 被抹成 0xFF */
		memcpy(image + 0x800, data, size);
		return true;
	}
	return false;
}
```

**为什么路径 B 会变砖**：`0x0..0x800` 不是填充，是真正的 ARM32 启动代码：

```
00000000:  e320f000  nop                         ×16（流水线对齐）
00000040:  e59f00cc  ldr  r0, [pc, #204]
00000044:  ee010f10  mcr  15, 0, r0, cr1, cr0, {0}   写 SCTLR
00000048:  f57ff06f  isb  sy
0000004c:  f1020016  cps  #22                        切换处理器模式
00000058:  ee0c0f10  mcr  15, 0, r0, cr12, cr0, {0}   设 VBAR
00000064:  eb000168  bl   0x60c                      调用子程序
00000080:  ee010f11  mcr  15, 0, r0, cr1, cr1, {0}    启用 MMU
```

抹掉之后 SoC 从 `0x0` 取指遇到全 `0xFF`，串口无输出，需要拆机用编程器。

**正确构造方式**：

```bash
# 0x00000 - 0x00800   厂商 bootloader.bin 的前 0x800 字节，原样保留
# 0x00800 - 0x1CE00   preloader FIP（117,760 字节）
# 0x1CE00 - 0x20000   0xFF 填充
python3 - <<'EOF'
import pathlib
vendor = pathlib.Path('backup/foresee-5580a/bootloader.bin').read_bytes()
pre    = pathlib.Path('preloader.bin').read_bytes()
BLOCK  = 0x20000

out = bytearray(b'\xff' * BLOCK)
out[0:0x800] = vendor[0:0x800]
out[0x800:0x800+len(pre)] = pre
pathlib.Path('bl2-firstblock.bin').write_bytes(bytes(out))
EOF
```

**验证**：

```
大小        131,072 B
md5         e78881e9116522755a919e777d747988
0x800 处    01 00 64 aa      FIP 魔数
FIP entry   UUID[0]  5ff9ec0b-4d22-3e4d-a544-c39d81c73f0a
```

### 2.2 `fip-new.fip` —— 371,478 字节

BL31 + 新 U-Boot 的 FIP，写进 UBI 的 `fip` 卷。

**构造流程**：

```bash
# 1. 压缩新编译的 u-boot.bin
lzma -9 -c u-boot.bin > u-boot-new.lzma

# 2. 用 fiptool 替换现有 FIP 的 BL33 槽位
cp an7583-fiberhome-hg5580a-bl31-u-boot.fip new.fip
fiptool update --nt-fw u-boot-new.lzma new.fip
```

`fiptool` 要从 TF-A 源码树编译，不在 U-Boot 树里：

```bash
make -C tf-a/tools/fiptool -j4
```

**验证**：

```
条目  UUID[1] 47d4086d.. offset=0x88    size=0xd622    BL31
      UUID[2] d6d0eea7.. offset=0xd6aa  size=0x4d46c   U-Boot
uuid bitmask 必须是 0x6（UUID[1] | UUID[2]）
```

**验证时要注意**：FIP 里 U-Boot 是 LZMA 压缩的，直接 `strings` 搜功能字符串**搜不到**。
必须解压后再查：

```bash
fiptool unpack --nt-fw /tmp/bl33.lzma new.fip
lzma -dc /tmp/bl33.lzma > /tmp/uboot.bin
strings /tmp/uboot.bin | grep F35SQB002G      # FORESEE 支持
```

### 2.3 `bosa.bin` —— 262,144 字节

BOSA 光模块校准，写进 UBI 的 `bosa` 卷。

**数据源有个坑**：`bosacal` 分区在本机实测是**全 `0xFF` 空白**：

```
bosacal-manifest.txt   0xec00000 0x20000 BLANK 154803cc
identity-manifest.txt  0xec20000 0x20000 BLANK 154803cc
```

真正的校准表在 `bosacal-table-2048.bin`（不是分区 dump）：

```
0x0000  "fiberhomebdbob"        厂商标识
0x0010  "202404291559VB"        日期 + 版本
0x0095  "ux3363"                光模块型号
0x00a5  "   GPON               " PON 制式
0x0600  "UX33631"
live    0x00000 .. 0x00606      592 字节
```

内核从卷偏移 `0x2` 读 `0x800` 字节：

```dts
bosa_calibration: calibration@2 { reg = <0x2 0x800>; };
```

**构造**：

```python
out = bytearray(b'\xff' * 262144)
out[0x2:0x2+592] = bosacal_table[0:592]
```

**验证**：`ux3363` 和 `fiberhome` 两个字符串必须能在前 `0x800` 里找到。

### 2.4 `ri.bin` —— 262,144 字节

MAC 与 PON 序列号，写进 UBI 的 `ri` 卷。

内核读取布局：

```dts
fh_base_mac:    mac-address@0  { reg = <0x0  0x6>; };
fh_lan_mac:     mac-address@6  { reg = <0x6  0x6>; };
fh_pon_serial:  pon-serial@c   { reg = <0xc  0x8>; };
fh_pon_mac:     mac-address@14 { reg = <0x14 0x6>; };
```

**构造**：

```python
base = bytes.fromhex('24E3A4B2DDE0')            # factory_conf 的 MAC
lan  = base[:5] + bytes([(base[5]+1) & 0xff])
pon  = base[:5] + bytes([(base[5]+2) & 0xff])
sn   = bytes.fromhex('46485454C255B8F9')        # factory_conf 的 GponSN

out = bytearray(b'\xff' * 262144)
out[0x00:0x06] = base
out[0x06:0x0c] = lan
out[0x0c:0x14] = sn
out[0x14:0x1a] = pon
```

### 2.5 `sysupgrade-new.itb`

PonWrt 固件。验证：

```bash
mkimage -l sysupgrade.itb | grep 'Load Address'
# 必须是 0x88000000，不能是 0x80200000
```

`0x80200000` 会撞上 `an7583.dtsi` 里的 NPU 预留窗口（`0x84000000`–`0x86e00000`），
28 MiB 的 lzma 内核解压后越界，`lmb` 拒绝：

```
Uncompressing Kernel Image to 80200000
Unable to allocate memory 0x80200000 for loading OS
```

---

## 3. 刷机流程

### 3.1 进入 U-Boot

原厂 U-Boot 的 autoboot 倒计时只有几秒，且只在**冷启动**时出现（热复位会跳过）。

```
串口 115200 8N1
断电 → 上电 → 立刻持续发送回车（每 150 ms 一个）
看到 "Hit any key to stop autoboot" 就说明抢到了
然后登录（原厂口令）
```

如果一直抢不到，检查：
- 波特率是否被改过（备选 57600 / 38400 / 19200 / 9600）
- 原厂固件是否已静默（Web 只有 80/8080 两个静态页面时说明内核在跑）

### 3.2 加载我们的 U-Boot（RAM，不写 flash）

```
setenv ipaddr 192.168.0.1
setenv serverip 192.168.0.2
setenv netmask 255.255.255.0
setenv ethact eth@1fb59000
ping 192.168.0.2
tftpboot 0x90000000 u-boot-52.bin
go 0x90000000
```

`u-boot-52.bin` 必须是 `u-boot.bin` 与 `u-boot.dtb` 的拼接（OF_SEPARATE 配置）：

```bash
cat u-boot.bin u-boot.dtb > u-boot-52.bin
```

否则 `go` 会回退到 `fdtcontroladdr`（原厂 DT），找不到 `ubi` 分区。

启动后应看到：

```
U-Boot 2026.07
spi_nand nand@0: FORESEE SPI NAND was found.
spi-nand: 256 MiB, block size: 128 KiB, page size: 2048, OOB size: 64
U-Boot HG5580A
HTTP management: http://192.168.0.1/
```

### 3.3 六个刷写步骤

**顺序不可调整。** `flash-bl2` 之后设备只能靠 UBI 启动。

```powershell
# ① 写 BL2（131,072 字节，路径 A）
POST /api/task  upload  bl2-firstblock.bin      → upload_id
POST /api/task  {"operation":"flash-bl2","upload_id":<id>}

# ② 重建 UBI 容器（会自动创建 fip / ubootenv / ubootenv2 / bosa / ri）
POST /api/task  {"operation":"ubi-rebuild"}

# ③ 写 BOSA 校准（262,144 字节）
POST /api/task  upload  bosa.bin                → upload_id
POST /api/task  {"operation":"flash-board-data","target":"bosa","upload_id":<id>}

# ④ 写板级身份（262,144 字节）
POST /api/task  upload  ri.bin                  → upload_id
POST /api/task  {"operation":"flash-board-data","target":"ri","upload_id":<id>}

# ⑤ 写 BL31 + U-Boot 到 UBI 的 fip 卷（371,478 字节）
POST /api/task  upload  fip-new.fip             → upload_id
POST /api/task  {"operation":"flash-fip","upload_id":<id>}

# ⑥ 写固件到 UBI 的 fit 卷
POST /api/task  upload  sysupgrade-new.itb      → upload_id
POST /api/task  {"operation":"flash","upload_id":<id>}
```

**每一步的约束**：

| 步骤 | 约束 | 违反了会怎样 |
| --- | --- | --- |
| ① | 必须 131,072 字节 | 小尺寸走路径 B，抹掉启动代码 → 变砖 |
| ③④ | 必须精确 262,144 字节 | `buffer_size != storage_request.size` → `-EINVAL` |
| ⑤ | UUID bitmask 必须 0x6 | `boot_fip_valid` 拒绝 |
| ①⑤ | 必须带 `upload_id` | `{"error":"invalid request"}` |

**③④ 为什么不能省**：`create_recovery_layout()` 只建**空卷**：

```c
ret = board_data_config(index, &board_data);
if (ret == -ENOENT)
	return 0;                  /* 报成功，但什么也没建 */
```

空 `bosa` 卷 → BOSA 驱动拿到全 0 校准 → probe 失败 → `pon0` 不出现。

### 3.4 验证

```sh
cat /proc/mtd
# 应该只有 6 项：all_flash / bl2 / ubi / factory / bosacal / identity

ls /sys/class/ubi
# 应该有 ubi0

for d in /sys/class/ubi/ubi*/name; do
	echo "$(basename $(dirname $d))=$(cat $d)"
done
# 应该列出 bosa / fip / fit / ri / ubootenv / ubootenv2

ip -br link
# 关键：pon0 必须出现

cat /sys/class/net/pon0/carrier
# 接光纤后应为 1

lsmod | grep -iE 'pon|bosa|xpon'
# airoha_paged_bosa 的引用计数应该 >= 1
```

**判据：`pon0` 出现即说明 UBI 修复成功。** 因为 `pon0` 依赖 `bosa` 卷的校准，
而 `bosa` 卷能读到说明 UBI 挂载正常、卷内容正确。

---

## 4. 失败恢复

### 4.1 分级判断

```
现象                                 严重程度    恢复方式
----------------------------------------------------------------------
刷完 bl2 后串口无任何输出             严重        §4.3
刷完 bl2 后有输出但停在 UBI 错误       中等        §4.2
能启动但 pon0 不存在                  轻          §4.4
能启动但 MAC 随机                      轻          §4.5
刷机过程中断电                         看阶段      §4.2 / §4.3
```

### 4.2 UBI 相关失败（可救）

**症状**：

```
ubi0 error: scan_peb: bad image sequence number in PEB n
UBI error: cannot attach mtdN
UBI init error 22
```

**原因**：UBI 容器损坏，或 `ubi` 分区偏移与 BL2 期望不符。

**恢复**：

```
1. 冷启动，抓 autoboot
2. tftpboot + go 加载我们的 U-Boot（RAM）
3. 确认分区表正确：
     从 /api/storage 看 bl2 和 ubi 的偏移
     bl2 必须是 0x0 + 0x20000
     ubi 必须是 0x20000 + 0xe6e0000
4. 重新 ubi-rebuild
5. 重新 flash-fip
6. 重新 flash（固件）
```

**关键**：我们的 U-Boot 在 DRAM 里，**只要不重新上电就一直可用**。
所以发现 UBI 问题时不要断电，立刻用 Web API 修。

### 4.3 BL2 相关失败（可能需要拆机）

**症状**：上电后串口完全无输出，连 BL2 的早期打印都没有。

**原因**（按可能性排序）：
1. 用了 `preloader.bin`（117,760 B）而不是 `bl2-firstblock.bin`，走了路径 B
2. `bl2` 分区大小不是 128 KiB，`flash-bl2` 拒绝了但被忽略
3. FIP 里的 UUID[0] 载荷损坏

**先尝试无拆机恢复**：

```
1. 断电，等 10 秒
2. 上电，同时持续发回车（我们的 BL2 可能有 autoboot）
3. 如果出现 U-Boot 提示符 → 立刻按 §4.2 的流程重刷
```

**如果还是完全无输出**：

BL2 的恢复需要外部编程器，因为 Boot ROM 只从 `0x800` 读 FIP，
而那段代码已经坏了。步骤：

```
1. 拆下 SPI-NAND（或在线夹 SOIC-8 测试夹）
2. 用编程器读出现有内容，确认损坏范围
3. 写回备份的 bootloader.bin（2.5 MiB，md5 986fee15e5ad66ead92cadc7089ebb44）
   写入地址 0x0
4. 装回，上电
```

**原厂 bootloader.bin 前 0x800 字节**是那段 ARM32 代码，
后 `0x800..0x76263` 是含 9 个 entry 的 FIP。
只要这个文件完整，就能恢复。

**没有备份怎么办**：从另一台同型号设备读（但 `factory` 分区不能混用，
因为 MAC 和 PON 序列号不同）。

### 4.4 `pon0` 不存在

**症状**：系统能启动，`/proc/mtd` 正确，UBI 挂载正常，但 `ip link` 里没有 `pon0`。

**按顺序排查**：

```sh
# 1. bosa 卷内容是否是校准数据而不是全 0
ubiattach -m 7 -d 0
ubirmvol ...
# 或者直接看驱动有没有报错
dmesg | grep -i bosa

# 2. 驱动是否加载
lsmod | grep paged_bosa
# 引用计数 0 说明没绑定到设备

# 3. I2C 上是否有 BOSA
ls /sys/bus/i2c/devices/
# 应该看到 0-0051

# 4. 设备树里的 nvmem-cells 是否能解析
ls /sys/firmware/devicetree/base/
```

**如果是 `bosa` 卷内容不对**：重新 `flash-board-data target=bosa` 并确保
用的是 `bosacal-table-2048.bin` 而不是那个全 `0xFF` 的 `bosacal.bin`。

### 4.5 MAC 地址随机

**症状**：

```
Warning: airoha-gdm1 (eth0) using random MAC address - c2:3b:a4:e8:11:8e
```

**原因**：`ethaddr_factory` 的偏移错了。这个是从 Nokia 布局抄来的 `0x3e`，
但本板 `ri` 卷的 MAC 在 `0x00`：

```sh
# 错的
ethaddr_factory=run ubi_mount && ubi read 0x90000000 ri && env readmem -b ethaddr 0x9000003e 0x6
#                                                     Nokia 的偏移 ↑

# 对的
ethaddr_factory=run ubi_mount && ubi read 0x90000000 ri && env readmem -b ethaddr 0x90000000 0x6
```

**修复**：改 `uboot-port/board/an7583_fiberhome_hg5580a.env`，重编 U-Boot，重打 FIP，重刷。

---

## 5. 光测速

### 5.1 前置条件

```
✅ pon0 存在
✅ airoha_paged_bosa 引用计数 >= 1
✅ /etc/config/pon 有 xpon section
   option device 'pon0'
✅ iperf3 已安装
❌ 光纤接入
❌ 与 OLT 完成注册
```

### 5.2 注册流程

```sh
# 1. 看驱动实际用的模式（默认 XGPON）
ponctl --device pon0 mode show

# 2. 看身份是否写入
ponctl --device pon0 identity show

# 3. 看 PON 状态
ponctl --device pon0 status

# 4. 拿地址
udhcpc -i pon0
ip -4 addr show pon0
```

### 5.3 PLOAM 状态判读

```
O5（Operational）        → 注册成功，可以测速
O1 / O2                  → 光功率不足或波长不匹配
O3 / O4 之后失败         → 序列号或密码与 OLT 不匹配
```

**如果停在 O3/O4**：检查 `ri` 卷里的 `GponSN` 与 OLT 侧配置是否一致。
本机从 factory 取出的是 `46485454C255B8F9`（`FHTT` + `C255B8F9`）。

### 5.4 一个已知的制式矛盾

`factory_conf` 里的字段名是 `GponSN` / `GPONPassWord`（GPON 制式），
但驱动不支持 GPON：

```c
static const struct airoha_xpon_mode_info airoha_xpon_modes[] = {
	{
		.mode = AIROHA_XPON_MODE_GPON,
		.name = "gpon",
		.frontend_mode = AIROHA_PON_FRONTEND_MODE_GPON,
		.control_protocol = AIROHA_XPON_CONTROL_OMCI,
		/* 没有 .mac_supported —— 六种里唯一被排除的 */
	},
	{ .name = "xgpon",       .mac_supported = true },
	{ .name = "xgspon",      .mac_supported = true },
	{ .name = "epon-1g",     .mac_supported = true },
	{ .name = "epon-10g-1g", .mac_supported = true },
	{ .name = "epon-10g-10g",.mac_supported = true },
};
```

驱动默认模式是 XGPON：

```c
int airoha_xpon_mode_get_default(struct device *dev, enum airoha_xpon_mode *mode)
{
	*mode = AIROHA_XPON_MODE_XGPON;
	/* DTS airoha,default-line-mode > bootargs > 上面的默认值 */
}
```

所以 `/etc/config/pon` 里 `option mode ''` 是空的**不影响**——
`/etc/init.d/pon` 的 `[ -n "$mode" ]` 会跳过 `ponctl mode set`，驱动按 XGPON 走。

如果接上光纤后 PLOAM 一直不上去，把 `mode` 显式设成 `xgpon` 再试。

### 5.5 测速

```sh
# 服务端（另一台机器）
iperf3 -s

# 客户端（HG5580A）
iperf3 -c <server-ip> -t 30 -P 4
```

**注意**：YT8821 在部分固件下只协商到 10baseT HDX，会限制到约 590 KiB/s。
这是 PHY 协商问题，不是 PON 性能问题。测 PON 速率要用 `pon0` 而不是 LAN 口。

---

## 6. 关键数据速查

### 6.1 已备份文件的校验值

| 文件 | 大小 | md5 |
| --- | --- | --- |
| `bootloader.bin` | 2,621,440 | `986fee15e5ad66ead92cadc7089ebb44` |
| `factory.bin` | 5,242,880 | `ab153adfd50625a7f83cf065894a37cc` |
| `bootflag.bin` | 524,288 | `61516d100878010dc81a20f1601eaa69` |
| `apps.bin` | 93,708,288 | `afb0594cb31a5283ab92648b5654d12d` |
| `userdata.bin` | 6,602,752 | `672af5af4b6ae41ffad3014ae9ef750c` |
| `fhbak.bin` | 3,428,352 | `8294082df7419ba7c4a810029913e928` |

### 6.2 刷机载荷的校验值

| 文件 | 大小 | md5 |
| --- | --- | --- |
| `bl2-firstblock.bin` | 131,072 | `e78881e9116522755a919e777d747988` |
| `bosa.bin` | 262,144 | `5d0aad4fc825140a7bbf9786df3e2773` |
| `ri.bin` | 262,144 | `72fac381e1cdfad4d083db21a1ef49d0` |
| `fip-new.fip` | 371,478 | `d7c3e42a7581e077ca1882e30dd3e8e1` |
| `sysupgrade-new.itb` | 34,165,006 | `0964f3584c39644fabc2683116ff6f6b` |
| `u-boot-52.bin` | 914,464 | `4b0d23f551280cc49160fa87bb0586e5` |

### 6.3 关键地址

```
DRAM 基址              0x80000000
内核加载地址            0x88000000      （避开 NPU 预留窗口）
NPU 预留窗口            0x84000000 - 0x86e00000
U-Boot 运行时           约 0x9ea89370
TFTP 加载地址           0x90000000
BL2 FIP 读取偏移        0x800
UBI 起始               0x20000
擦除块                  0x20000（128 KiB）
页大小                  2048
OOB                     64（FORESEE）/ 128（SkyHigh）
```

### 6.4 两种闪存批次

同一块主板上出现过两种 SPI-NAND，**U-Boot 必须都支持**：

| 型号 | mfr | dev | OOB | 容量 |
| --- | --- | --- | --- | --- |
| SkyHigh S35ML02G300 | `0x01` | `0x25` | 128 | 256 MiB |
| FORESEE F35SQB002G | `0xCD` | `0x52` | 64 | 256 MiB |

FORESEE 需要在 `drivers/mtd/nand/spi/foresee.c` 里加表项：

```c
SPINAND_INFO("F35SQB002G",
	     SPINAND_ID(SPINAND_READID_METHOD_OPCODE_DUMMY, 0x52, 0x52),
	     NAND_MEMORG(1, 2048, 64, 64, 2048, 40, 1, 1, 1),
	     NAND_ECCREQ(1, 512),
	     ...,
	     SPINAND_HAS_QE_BIT,
	     SPINAND_ECCINFO(&f35sqa002g_ooblayout, &f35sqa002g_ecc_get_status)),
```

不加会报：

```
spi_nand nand@0: unknown raw ID cd 52 52 cd
```

---

## 7. 常见构建问题

刷机之前要先能编译出镜像。构建过程中踩过的坑：

| 现象 | 原因 | 修法 |
| --- | --- | --- |
| 23 个工具「缺失」（`g++ tar find`…） | WSL 继承了含空格的 Windows PATH，`toplevel.mk` 按空格重新切分 | `export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` |
| `should not run configure as root` | WSL 是 uid 0 | `export FORCE_UNSAFE_CONFIGURE=1` |
| 构建中途消失，无错误 | `Select-Object -Last N` 持有管道，作业清理时发 SIGHUP | `setsid nohup ... >> log 2>&1 < /dev/null &` |
| WSL 实例整个重启，rustc 编译丢失 | `.wslconfig` 里 `memory=20GB`，主机只有 23.9 GB | 改成 `memory=12GB`，`swap=16GB` |
| `grep: binary file matches` | ninja/apk/go 往 stdout 写二进制 | 用 `strings log` 或 `grep -a` |
| `ninja: error: unknown target 'install'` | 前次中断留下残缺的 `build.ninja` | `rm -rf build_dir/hostpkg/apk-*` |
| `Exec format error: .../lua5.1` | 中断留下 0 字节文件 | `rm -rf build_dir/hostpkg/lua-*` 并删 stamp |
| `make: No targets.  Stop.` | csstidy 整个源码树被截断成 0 字节 | `rm -rf build_dir/hostpkg/csstidy-*` |

**判断「是代码问题还是缓存污染」的方法**：

```
同一个错误在「删掉 build_dir/<pkg> 后重跑」时消失  → 缓存污染
仍然出现                                        → 真实问题
```

**如何发现 0 字节污染**：

```bash
# stamp 文件本来就该是 0 字节，不要误删
for d in staging_dir/host/bin staging_dir/hostpkg/bin; do
  for f in "$d"/*; do
    [ -f "$f" ] && [ ! -L "$f" ] && [ "$(stat -c %s "$f")" -eq 0 ] && echo "ZERO: $f"
  done
done
```

---

## 8. 一句话总结

**这台设备能刷，前提是三件事都对：**
1. `bl2` 分区恰好 128 KiB，且用 `bl2-firstblock.bin`（不是 `preloader.bin`）
2. `ubi` 从 `0x20000` 开始，正好停在 `factory` 之前
3. `bosa` / `ri` 卷要有真实内容，不能靠 `ubi-rebuild` 的空卷

**三件事有一件错，设备不会启动。** 好消息是 `factory` 和 `bootloader` 都在
UBI 窗口外，且有备份，最坏情况可以用编程器恢复。
