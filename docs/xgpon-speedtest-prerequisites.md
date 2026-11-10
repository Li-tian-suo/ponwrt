# XG-PON 光测速的前置条件

> 最终目标是在 HG5580A 上跑一次光口吞吐。本文把「能不能测」拆成可验证的
> 条件链，并说明每一环怎么确认。

---

## 1. 为什么不能直接测

「上光测速」不是一条命令，而是一串依赖。任何一环断了，测出来的数字都没有意义：

```
光模块驱动绑定
   ↓
pon0 网络设备出现
   ↓
PON MAC/PCS 初始化
   ↓
物理链路 up（carrier=1）
   ↓
OMCI / 注册完成（O5 状态）
   ↓
能收发以太帧
   ↓
测速才有意义
```

每一环都有独立的失败模式，所以要先确认链路走到哪一步。

---

## 2. 硬件前提

| 项 | HG5580A | 说明 |
| --- | --- | --- |
| 光模块 | Airoha **UX3363** paged BOSA | i2c0 地址 `0x51` |
| PON 类型 | **XG-PON** (10G/2.5G) | `serdes_pon` 走 `xpon_usxgmii` |
| 驱动 | `kmod-airoha-paged-bosa` | 提供 `optical-front-end` |
| 协议栈 | `kmod-airoha-xpon` | 提供 `pon0` |
| 用户态 | `airoha-ponctl` / `airoha-pond` | 控制与守护 |
| 光纤 | **必须有** | 无光纤则 carrier 永远为 0 |

### GPON 不支持

`airoha-xpon-mode.c` 里 GPON 的入口**故意省略了** `.mac_supported = true`：

```c
/* GPON 条目没有 .mac_supported */
```

于是 `main.c:200` 会返回 `-EOPNOTSUPP`。PCS 层支持 GPON，但 MAC 层不支持。

对本机无影响 —— 线路是 XG-PON。

---

## 3. 逐环检查

### 3.1 驱动绑定

```sh
lsmod | grep -E 'xpon|paged_bosa'
# 期望看到:
#   airoha_xpon
#   airoha_paged_bosa
```

如果缺，检查 DTS 的 BOSA 节点是否被绑定：

```sh
ls /sys/bus/i2c/devices/
# 期望有一个 0-0051，name 为 optical-front-end@51 之类
cat /sys/bus/i2c/devices/0-0051/name
```

### 3.2 `pon0` 出现

```sh
ip link show pon0
```

没有的话看 dmesg：

```sh
dmesg | grep -iE 'xpon|pon_pcs|bosa'
```

典型的失败信息：

| 日志 | 含义 |
| --- | --- |
| `airoha_pon_frontend_get() failed` | BOSA provider 没注册（驱动没编进去或没绑定） |
| `probe failed with error -517` | `-EPROBE_DEFER`，依赖还没就绪（通常会重试） |
| `calibration invalid` | `bosacal` 数据格式不对（本机是原厂私有格式，未解析） |

### 3.3 校准数据

DTS 里 BOSA 节点通过 `nvmem-cells = <&bosa_calibration>` 取校准：

```dts
&i2c0 {
	hg5580a_bosa: optical-front-end@51 {
		compatible = "airoha,paged-bosa";
		nvmem-cells = <&bosa_calibration>;
		nvmem-cell-names = "calibration";
	};
};
```

而 `bosa_calibration` 来自 UBI 的 `bosa` 卷（在 UBI parts DTS 里定义为
`nvmem-layout` 的 `calibration@2`）。

**这意味着**：`bosa` 卷必须是有效的，否则校准读出来是 0xFF，
光功率上报会不准（但链路本身仍可能起来）。

### 3.4 链路状态

```sh
cat /sys/class/net/pon0/carrier
cat /sys/class/net/pon0/operstate
```

`carrier=1` 才说明物理层通了。**没有光纤时这一步必然为 0。**

### 3.5 注册状态

XG-PON 的 ONU 注册状态机（O1-O7）通常通过厂商工具读取：

```sh
airoha-ponctl status
```

或者读 debugfs（如果有）：

```sh
find /sys/kernel/debug -iname '*pon*' 2>/dev/null
```

**O5** 才是「注册完成、可以承载业务」的状态。

---

## 4. 测速方案

链路 up 且有业务通道之后，测速有三种可行方式：

### A. 网口到网口（验证交换/路由性能，不含光）

```sh
# PC 接 lan1（2.5G YT8821），另一台设备接 lan2
iperf3 -s            # 设备侧
iperf3 -c <device>   # PC 侧
```

这把 2.5G PHY 和 MT7530 交换都测了，但**不经过光口**。
适合作为基线 —— 如果这一步都跑不满，光口更不可能。

### B. 光口到光口（真正的光测速）

需要两端都是 XG-PON：

```
ONU (HG5580A) ──光纤── OLT ──上行网络── 测速服务器
```

在 ONU 上跑：

```sh
iperf3 -c <server> -t 30 -P 4
```

理论上行 2.5G / 下行 10G，实际受限于：
- OLT 配置的带宽模板（通常远低于线速）
- ONU 注册的业务类型
- 上游链路

**「上光测速」通常指这一项。**

### C. 光模块环回（无 OLT 时验证物理层）

把同一模块的 TX 接到 RX（需 attenuator），检查：
- 是否有光功率读数
- carrier 是否翻转

这只能验证模块活着，**测不出吞吐**。

---

## 5. 当前阻塞点

| 条件 | 状态 | 说明 |
| --- | --- | --- |
| U-Boot 能启动 | ✅ | 实机 RAM 测试通过 |
| 固件能启动 | ⏳ | 加载地址已修，待新固件验证 |
| 驱动编进固件 | ✅ | `CONFIG_PACKAGE_kmod-airoha-paged-bosa=y` 等已确认 |
| `pon0` 出现 | ⏳ | 需固件启动后验证 |
| **光纤接入** | ❌ | **工作环境无光纤** |
| OLT 可用 | ❌ | 同上 |

**光测速卡在物理条件上，不是软件问题。**

---

## 6. 光纤到位后的步骤

1. 确认 `pon0` 存在，`lsmod` 有驱动
2. `cat /sys/class/net/pon0/carrier` → 应为 1
3. `airoha-ponctl status` → 应到 O5
4. 配 `pon0` 的 IP（或让它桥接到某个网口）
5. 基线：先测网口 iperf3（验证 CPU/交换能力）
6. 光口：`iperf3 -c <server>` 测下行，`-R` 测上行
7. 记录：带宽、CPU 占用、丢包、RTT

### 需要注意

- **YT8821 在 U-Boot 里只协商到 10baseT HDX** —— 这是原厂 U-Boot 的老问题，
  进了 Linux 之后由内核驱动接管，应该能协商到 2.5G。这一点需要实测确认。
- **CPU 是 2× Cortex-A53**，做 10G 线速转发可能受限，测速时观察
  `top` / `mpstat`。
