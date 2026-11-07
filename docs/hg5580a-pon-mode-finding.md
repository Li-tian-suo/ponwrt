# HG5580A PON 模式调查结论（2026-11-08）

> 本文是对 PON 无法同步问题的**根因定位报告**。
> 结论：**PonWrt 的上游 airoha-xpon 驱动不支持 GPON**，这是功能缺口，不是移植错误。

## 一、现象

启动后 PON 无限重试：

```
airoha-xpon: PON resources bound to pon0; mode=xgpon, MAC irq=29, PHY irq=30
airoha-xpon: XG-PON RX started, irq=29, ONU-ID=1023 (invalid), burst TX remains disabled
airoha-xpon: optical signal present without XGTC sync; running short PMA recovery (recovery N)
```

`recovery N` 会一直增长（实测到 168+ 次），永远不同步。

## 二、证据链

### 2.1 这台设备是 GPON ONU

厂商 `factory_conf`（从 `factory` 分区的 `fhdata` UBI 卷提取）：

```
config key 'GponSN'        option value '4648545400244D02'
config key 'GPONPassWord'  option value '48473236303132333435'   → "HG26012345"
config key 'pon_mode'      option value '4'      ← 镜像默认
config key 'VendorCode'    option value 'FH'
```

**本机实际** `pon_mode = 2`（镜像里是 4），说明模式是逐台写入的工厂配置。

### 2.2 驱动默认是 XG-PON

`feeds/pon_drivers/airoha-xpon/src/airoha-xpon-mode.c:118`：

```c
*mode = AIROHA_XPON_MODE_XGPON;                                    // 默认
if (!of_property_read_string(dev->of_node, "airoha,default-line-mode", &name))
        ret = airoha_xpon_mode_parse(name, mode);                  // ① DTS
...
ret = of_property_read_string(chosen, "bootargs", &bootargs);
... if (strcmp(param, "xpon.mode")) continue;                       // ② cmdline（优先）
```

我们的 DTS **没有** `airoha,default-line-mode`，所以走默认 XG-PON。

**注意**：UCI 里的 `pon.line0.mode` 内核**根本不读**（已实测验证，设了无效）。

### 2.3 XG-PON ONU 永远无法与 GPON OLT 同步

两种 PON 的线路速率、帧结构（GTC vs XGTC）、同步序列都不同。
所以 `optical signal present without XGTC sync` 是必然结果——收到的是 GTC 帧，找的是 XGTC 同步头。

### 2.4 切换到 GPON 后驱动直接报不支持

U-Boot 里加 `xpon.mode=gpon` 启动：

```
PON resources bound to pon0; mode=gpon, MAC irq=29, PHY irq=30    ← 模式切换成功
airoha_eth 1fb50000.ethernet pon0: failed to queue PON line start: -95
```

`-95 = -EOPNOTSUPP`（操作不支持）。

### 2.5 源码层面确认：没有 GPON 实现

`feeds/pon_drivers/airoha-xpon/src/` 只有：

```
airoha-xpon-epon.c       ← EPON / EPON-10G
airoha-xpon-xgpon.c      ← XG-PON / XGS-PON
airoha-xpon-ploam.c
airoha-xpon-mode.c
...
（没有 airoha-xpon-gpon.c）
```

`airoha-xpon-mode.c` 的模式表里虽然有 `{ .mode = AIROHA_XPON_MODE_GPON, .name = "gpon" }`，
但那只是一个枚举项 + 名字，**没有对应的 MAC 层实现**。

## 三、影响评估

| 能力 | 状态 |
| --- | --- |
| 以太网 / DSA 交换 | ✅ 完全正常 |
| 2.5G PHY (YT8821) | ✅ 正常 |
| LAN1–LAN4 | ✅ 正常（lan2、lan3 已实测 Link Up 1Gbps） |
| 光模块 UX3363 识别 | ✅ 正常（ID 55583333363331） |
| pon0 / omci0 / oam0 创建 | ✅ 正常 |
| **GPON 线路同步** | ❌ 驱动不支持 |
| XG-PON 线路同步 | ⚠️ 驱动支持，但本机是 GPON ONU，用不上 |

**即：这台设备在 PonWrt 上可以当一台 4 口交换机 / 有线路由器用，但无法当 GPON 光猫用。**

## 四、后续可选方向

1. **给上游驱动补 GPON 实现** —— 工作量大（需要 GPON MAC、PLOAM/GTC 帧处理、OMCI over GTC），
   但这是唯一能让这台设备当光猫用的路。

2. **换一台 XG-PON 的机器验证** —— 如果只是想验证驱动本身，可以用 XG-PON OLT 环境。

3. **接受现状** —— 当交换机/路由器用，PON 部分留着不动。

## 五、顺带修好的问题

### 5.1 MAC 告警

`931-net-airoha-share-fallback-mac-base-across-gdms.patch`（commit `dcfc7d2`）已生效：

```
airoha_eth: GDM1 has no usable MAC, using 22:8e:65:90:ae:c1 (base 22:8e:65:90:ae:bd)
airoha_eth: GDM2 has no usable MAC, using 22:8e:65:90:ae:c5 (base 22:8e:65:90:ae:bd)
airoha_eth: GDM3 has no usable MAC, using 22:8e:65:90:ae:c9 (base 22:8e:65:90:ae:bd)
```

三个 GDM 共用 OUI，`dmesg | grep -iE "wrong mac|MSBs|FE hw"` **零匹配**。

### 5.2 LAN3

实测已经正常：

```
mt7530-mmio 1fb58000.switch lan3: Link is Up - 1Gbps/Full - flow control rx/tx
br-lan: port 3(lan3) entered forwarding state
```

### 5.3 PON 序列号

`identity` 分区全 `0xFF` 导致：

```
airoha-xpon: ignoring invalid default PON serial (8 bytes)
```

**临时验证方法**（不写 flash）：

```sh
rmmod airoha-xpon
insmod /lib/modules/6.18.55/airoha-xpon.ko serial_number=46485454C255B8F9
```

实测该告警消失，`/sys/module/airoha_xpon/parameters/serial_number` = `46485454C255B8F9`。
但这**不能**解决同步问题——因为同步失败是模式不匹配，不是序列号。

## 六、附：光模块校准

```
airoha-paged-bosa 0-0051: UX3363 frontend registered, ID 55583333363331, calibration invalid
```

`bosacal` 分区（mtd11）内容是**厂商自有格式**：

```
00000000  66 69 62 65 72 68 6f 6d 65 62 64 62 6f 62 00 00  |fiberhomebdbob..|
00000010  32 30 32 34 30 34 32 39 31 35 35 39 56 42 00 00  |202404291559VB..|
00000030  2e 00 00 ...                                      |................|
00000070  80 07 00 00 58 af f3 05 80 00 00 00 32 62 3b 33   |....X.......2b;3|
```

魔术字 `fiberhomebdbob` + 日期 `202404291559VB`，不是 Airoha `paged-bosa` 的格式，
所以驱动判定 `calibration invalid`。这影响收发光参数，但不影响能否同步上 PON 模式。
