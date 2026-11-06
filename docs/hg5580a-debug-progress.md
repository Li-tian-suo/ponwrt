# HG5580A 调试进度（2026-11-07）

> 本文记录 HG5580A 在 PonWrt 上的实测结果，供后续接续。
> 仓库：`Li-tian-suo/ponwrt-hg5380a` 分支 `Ponwrt-5380A`，HEAD `dcfc7d2`。

## 一、结论速览

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| 本地编译 | ✅ 完成 | 镜像已产出并校验 |
| 云编译（GitHub Actions） | ✅ 完成 | run `42264511127` 全绿，`Compile` 6846s |
| 上机启动（initramfs） | ✅ 完成 | `Machine model: FiberHome HG5580A` |
| MAC 告警修复 | ✅ 完成 | `dmesg` 里 `wrong mac`/`MSBs` 零匹配 |
| LAN2/3/4 | ✅ 正常 | `lan2: Link is Up - 1Gbps/Full`，lan3/4 仅未插线 |
| 2.5G PHY (YT8821) | ✅ 识别 | `driver [YT8821 2.5Gbps PHY]` |
| 光模块 UX3363 | ✅ 识别 | `UX3363 frontend registered, ID 55583333363331` |
| pon0 创建 | ✅ 完成 | `PON resources bound to pon0; mode=xgpon` |
| PON 业务同步 | ❌ 未完成 | 无 XGTC sync，`ONU-ID=1023 (invalid)` |

## 二、启动方法（关键！加载地址有坑）

### 2.1 必须用 0x88000000，不能用 0x82000000

```
解压后内核 Image = 35,586,056 B (33.94 MiB)，基址 0x80200000
→ 结束于 0x823f0008，已经越过 0x82000000
→ FIT 若放在 0x82000000 会被内核解压覆盖：
   ERROR: new format image overwritten - must RESET the board
```

正确命令序列：

```
ping 192.168.1.126
tftpboot 0x88000000 initramfs.itb
setenv bootargs console=ttyS0,115200 earlycon swiotlb=noforce
bootm 0x88000000
```

### 2.2 U-Boot 登录

- 上电后 autoboot 期间会被固件升级服务占用，出现 `Abort` 后给出 `UserName:` / `Password:` 提示。
- **关键陷阱**：登录期间不能继续发 Ctrl-C / CR。Ctrl-C 会清空当前输入行，
  导致 `UserName:` 只回显 1 个 `*`，密码被打进用户名字段。
- 正确做法：一旦看到 `UserName:` 或 `Password:`，立刻停止发任何打断键。
- 脚本已实现：`tools/bringup4.ps1`（含 8 处 bug 修复记录）、
  `tools/test-login-logic.ps1`（状态机单元测试，全部 PASS）。

### 2.3 串口

- COM4 = CH340 = HG5580A，115200 8N1。
- 断电会让 CH340 一起掉线（COM4 消失），需要等它重新枚举。
- `tools/bringup-wait.ps1` 会先等端口出现再接管。

## 三、MAC 问题的完整分析（已修）

### 3.1 现象

```
eth1: wrong mac addr, MSBs must be 36:f7:1d
FE hw forwarding won't work properly
```

### 3.2 三层根因

1. `identity` 分区（mtd12）**全 0xFF**，从未写过：
   `md5sum = 41d2e2c0c0edfccf76fa1c3e38bc1cf2`，非 0xFF 字节数 = 0。
2. `of_get_mac_address()` 逐项尝试 `mac-address` / `local-mac-address` /
   `address` / nvmem，每步都用 `is_valid_ether_addr()` 过滤，`FF:FF:…` 因为
   是组播地址而被拒。
3. 驱动退回 `eth_hw_addr_random()`，**每个 GDM 各随机一次**，于是三个 GDM
   前 3 字节各不相同 → `airoha_set_macaddr()` 拒绝 → 告警。

### 3.3 修法（commit `dcfc7d2`）

新增补丁 `target/linux/airoha/patches-6.18/931-net-airoha-share-fallback-mac-base-across-gdms.patch`
（3,474 B）：把随机基址提到 `struct airoha_eth` 里，所有 GDM 共用一个基址，
末字节按 `port->id << 2) + nbq` 区分。

### 3.4 实测验证

```
airoha_eth 1fb50000.ethernet: GDM1 has no usable MAC, using 66:2e:21:6a:8c:e8 (base 66:2e:21:6a:8c:e4)
airoha_eth 1fb50000.ethernet: GDM2 has no usable MAC, using 66:2e:21:6a:8c:ec (base 66:2e:21:6a:8c:e4)
airoha_eth 1fb50000.ethernet: GDM3 has no usable MAC, using 66:2e:21:6a:8c:f0 (base 66:2e:21:6a:8c:e4)
```

三个 GDM 共用 OUI `66:2e:21`：

```
dmesg | grep -iE "wrong mac|MSBs|FE hw"   →   零匹配
```

**注意**：该修法是「每机稳定、跨重启随机」，能消除告警、恢复转发，
但**不是真实厂商 MAC**。真正的 MAC 在 `factory` 分区的 `fhdata` UBI 卷里。

## 四、PON 不同步：当前唯一的阻塞点

### 4.1 现象

```
airoha-xpon: ignoring invalid default PON serial (8 bytes)
airoha-xpon: XG-PON RX started, irq=29, ONU-ID=1023 (invalid), burst TX remains disabled
airoha-xpon: optical signal present without XGTC sync; running short PMA recovery (recovery N)
```

有光（`optical signal present`），但每 3.5 秒重试一次，已重试 168+ 次。

### 4.2 驱动如何读序列号（`feeds/pon_drivers/airoha-xpon/src/airoha-xpon-identity.c`，仅 134 行）

```c
/* 41-68 行：优先 module 参数，否则读 nvmem cell "pon-serial" */
cell = devm_nvmem_cell_get(dev, "pon-serial");
identity = nvmem_cell_read(cell, &identity_len);

/* 21-33 行：全 0x00 或全 0xFF 判定为 blank */
static bool airoha_xpon_identity_is_blank(const u8 *data, size_t len)

/* 76-78 行：blank → goto invalid_nvmem → 打印我们看到的告警 */

/* 81-104 行：接受两种长度 */
if (identity_len == 8)        memcpy(serial_number, identity, 8);      /* 原始 8 字节 */
else if (identity_len == 12) { /* 4 字节可打印 + 8 个 ASCII hex */ }
else                          goto invalid_nvmem;

/* 16 行：module 参数要求 16 个 hex 字符 */
static char *serial_number;  module_param(serial_number, charp, 0400);
```

### 4.3 nvmem 布局（已在设备上实测确认）

```
/sys/firmware/devicetree/base/soc/spi@1fa10000/nand@0/partitions/partition@ec20000/
    mac-address@0        → 偏移 0x00，6 字节
    mac-address@6        → 偏移 0x06，6 字节
    pon-serial@c         → 偏移 0x0C，8 字节   ← 关键
    mac-address@14       → 偏移 0x14，6 字节
```

`pon-serial@c/reg` 实测 = `00 00 00 0c 00 00 00 08`。

### 4.4 真实序列号（来自 `backup/fhdata-files/factory_conf`）

```
GponSN        = 46485454C255B8F9   → 8 字节: 46 48 54 54 C2 55 B8 F9  ("FHTT" + C2:55:B8:F9)
GPONPassWord  = 48473236303132333435 → ASCII "HG26012345"
```

### 4.5 尚未排除的其他可能

写入序列号不一定能解决同步，因为 XGTC 同步还取决于：

- OLT 侧是否已注册该 ONU（LOID / 序列号白名单）；
- 该 PON 口是否已开通、光功率是否在范围内；
- `calibration invalid` —— 光模块校准数据缺失，可能影响收发参数：
  ```
  airoha-paged-bosa 0-0051: UX3363 frontend registered, ID 55583333363331, calibration invalid
  ```
  `bosacal` 分区（mtd11）之前被确认为全 `ff` 后才写入 `table`（crc32 `f1315e00`，内容含 `ux3363`），
  但当前启动日志仍报 `calibration invalid`，需要复查。

## 五、下次接续的推荐步骤

1. **先确认光路**：把 HG5580A 接到已知可用的 PON 口，或用光功率计确认收光。
2. **用 module 参数临时注入序列号，不写 flash**：
   ```
   insmod /lib/modules/6.18.55/airoha-xpon.ko serial_number=46485454C255B8F9
   ```
   若同步成功 → 说明就是序列号问题，再写 `identity` 分区固化。
3. **写 identity（只写序列号，8 字节 @ 0x0C）**：
   当前分区全 0xFF，擦除即还原，风险极低。
4. **复查 bosacal**：`calibration invalid` 可能独立影响光模块工作。

## 六、备份与安全

- 完整备份在 `backup/`（13 个文件，236.2 MiB，已与设备 CRC 核对）。
- **绝不写** `bootloader` 和 `factory` 分区。
- `identity`（mtd12）当前全 0xFF，写坏了擦掉就回到原状。
- 刷机顺序：先写 KernelB + RootfsB，用 `fhbootflag` 切换验证，再写 A 槽。
- `mtd erase` 后再 `mtd write`，用 `mtd read` + `crc32` 校验。

## 七、本次会话修复的脚本 bug（供参考）

`tools/bringup4.ps1` 的头注释记录了 8 个反复踩到的坑，核心两个：

1. **滚动窗口判断提示符** → 旧的 `Password:` 一直留在窗口里，导致密码被反复
   输入到用户名字段。改为只看**最新片段**。
2. **登录期间仍发 Ctrl-C** → 每次输入被清空。改为**看到提示符立刻停手**。

`tools/test-login-logic.ps1` 对这些逻辑做了脱离硬件的回归测试，避免再浪费上电机会。
