# HG5580A 光口测速的可行性：GPON MAC 层完全缺失

> 2026-11-08 调研结论。这一条决定“上光测速”能不能做。

## 一、硬件与协议栈分层现状

| 层次 | 状态 | 证据 |
| --- | --- | --- |
| 光模块 UX3363 | ✅ 识别正常 | `airoha-paged-bosa 0-0051: UX3363 frontend registered, ID 55583333363331` |
| SerDes / PCS | ✅ 有 GPON 档位 | `AIROHA_PCS_PON_MODE_GPON` 在枚举里 |
| **GPON MAC（GTC 成帧）** | ❌ **没有实现** | 见下 |
| PLOAM 状态机 | ❌ 只有 EPON/XG-PON 的 | 源文件只有 `-epon.c` 和 `-xgpon.c` |
| OMCI | ⚠️ 通用层在，但依赖 MAC | `airoha-xpon-omci.c` |

## 二、决定性证据

驱动源文件（`build_dir/.../airoha-xpon/`）：

```
airoha-xpon-epon.c     36,752 B   EPON
airoha-xpon-xgpon.c    27,146 B   XG-PON
（没有 airoha-xpon-gpon.c）
```

模式表（`airoha-xpon-mode.c`）里 GPON 那一条**故意不设 `mac_supported`**：

```c
{
    .mode = AIROHA_XPON_MODE_GPON,
    .name = "gpon",
    .frontend_mode = AIROHA_PON_FRONTEND_MODE_GPON,
    .control_protocol = AIROHA_XPON_CONTROL_OMCI,
    /* 没有 .mac_supported = true */
},
{
    .mode = AIROHA_XPON_MODE_XGPON,
    ...
    .mac_supported = true,      /* 其余五种模式都有 */
},
```

启动路径（`airoha-xpon-main.c:200`）直接拒绝：

```c
mode = airoha_xpon_mode_info(xpon->configured_mode);
if (!mode || !mode->mac_supported ||
    !airoha_pon_frontend_supports(xpon->frontend, mode->frontend_mode)) {
    ret = -EOPNOTSUPP;
    xpon->last_start_error = ret;
    goto out_unlock;
}
```

**-EOPNOTSUPP = -95**，正是之前 `uci set pon.line0.mode=gpon` 之后内核报的
`failed to queue PON line start: -95`。

而驱动默认值写死 XG-PON（`airoha-xpon-mode.c` 的
`airoha_xpon_mode_get_default()` 里 `*mode = AIROHA_XPON_MODE_XGPON;`），
所以不配置时它在 GPON 线路上无限重试：

```
airoha-xpon: optical signal present without XGTC sync;
             running short PMA recovery (recovery 441)
airoha-xpon: XG-PON RX started, ONU-ID=1023 (invalid), burst TX remains disabled
```

本机是 GPON ONU（`GponSN = 46485454C255B8F9`，`pon_mode = 2`）。

## 三、要支持 GPON 需要写什么

不是改配置或打个小补丁能解决的，需要实现完整的 GTC（GPON Transmission
Convergence）层：

1. **下行帧同步与成帧**：PCBd 结构、Psync 检测、Superframe 计数器
2. **BWmap 解析**：上行带宽授权、Alloc-ID 映射
3. **上行突发发送**：突发开销（前导、定界符）、激光器开关时序
4. **PLOAM 消息**：Upstream_Overhead、Serial_Number_ONU、Ranging_Time、
   Assign_ONU-ID、Encryption、Password、Configure_Port_ID
5. **测距（ranging）状态机**：O1..O7 状态迁移
6. **AES 加密**：GPON 的加密密钥交换与帧加密
7. **DBA 上报**：上行队列状态报告

参照已有的 `-xgpon.c` 结构可以复用框架，但 GTC 与 XGEM 的帧格式完全不同，
不能照搬。这是数千行驱动的量级。

## 四、因此“上光测速”当前可行的边界

| 目标 | 可行性 |
| --- | --- |
| PON 光口拨号上网后测速 | ❌ 需要先实现 GPON MAC |
| LAN 口之间测速（交换机模式） | ✅ 可以，homebox / iperf3 已编译 |
| LAN 到上游（若有以太网上联） | ✅ 可以 |
| 光模块光功率读取（DDM） | ✅ 可以，BOSA 驱动已识别模块 |

**建议**：先把 LAN 侧吞吐测起来（homebox 浏览器测速 + iperf3），
光口测速作为独立的大工程排期。

## 五、有没有捷径

设备上有没有厂商实现的 GPON 驱动可以参考？

`backup/` 里有完整的原厂分区镜像，但厂商用的是自己的内核（不是 6.18），
驱动是二进制模块，且 `factory` 卷里的东西没有源码。

唯一可能的捷径是找到 Airoha 官方的 GPON 参考实现，但公开渠道没有。

所以结论：**要 GPON，就得自己写。**
