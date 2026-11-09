# HG5580A 调试记录：已定位并修复的 bug

> 2026-11-08 实机调试。每条都有证据和修法。

## 环境

```
设备   FiberHome HG5580A，Airoha AN7583，512 MiB DRAM，256 MiB SPI-NAND
系统   PonWrt SNAPSHOT b1af9523，Linux 6.18.55
刷机   KernelB 放裸 FIT，bootcmd 改为 mtd read + bootm，绕过厂商签名校验
通道   COM4 串口 + SSH（root/admin）
```

---

## 1. 厂商 U-Boot 校验固件签名，ldkernel 路线走不通

**现象**：把 OpenWrt 内核按厂商格式包装后写进 KernelB，
`ldkernel` 打印 `Read FIT image total_size=5aa100`（格式正确），
然后卡在 `Loading image id=11` 之后，串口无输出、ping 不通。

**根因**：私有头里内嵌 `(offset,length)` 表，`ldkernel` 依次把三段搬到
`0x80045000`：

| id | 内容 | 长度 |
| --- | --- | --- |
| 7 | `Trusted Key Certificate` | 2,574 B |
| 11 | `Non-Trusted Firmware Key Certificate` | 2,026 B |
| 15 | `Non-Trusted Firmware Content Certificate` | 1,666 B |

三段都是 X.509 DER 证书。我们的镜像里它们与厂商原版逐字节相同
（sha256 一致），但被校验的固件内容变了，签名必然不匹配。

**修法**：绕开 `ldkernel`，直接 `bootm`：

```
setenv bootcmd "mtd read KernelB 0x88000000 0x0 0x600000; bootm 0x88000000"
saveenv
```

`bootm` 只校验 FIT 自带的 hash（我们自己生成的，对得上），
不做厂商签名校验。**已验证成功启动。**

---

## 2. RootfsB 不设 `linux,rootfs` 时内核找不到根设备

**现象**：

```
jffs2: Cowardly refusing to erase blocks on filesystem with no valid JFFS2 nodes
```

**根因**（`drivers/mtd/mtdcore.c:843`）：

```c
if (of_property_read_bool(of_node, "linux,rootfs") ||
    (CONFIG_MTD_ROOTFS_ROOT_DEV && !strcmp(mtd->name, "rootfs") && ROOT_DEV == 0))
        ROOT_DEV = MKDEV(MTD_BLOCK_MAJOR, mtd->index);
```

两条路，只有第一条能走：分区名是 `RootfsB`，不匹配 `"rootfs"` 那个字符串比较。

**修法**：给 `partition@3700000` 加 `linux,rootfs;`。
启动日志出现 `mtd: setting mtd5 (RootfsB) as root device` 即生效。

---

## 3. `luci-base` 不带 Web 服务器，LuCI 打不开

**现象**：镜像里有 243 个 LuCI 文件（`/www/cgi-bin/luci`、
`/etc/config/luci`、`luci-mod-admin-full`、`luci-app-pon`、rpcd 全套），
但 `/usr/sbin/uhttpd`、`/etc/init.d/uhttpd` 一个都没有。

**根因**：`feeds/luci/modules/luci-base/Makefile` 的依赖只有
rpcd / ucode / cgi-io / liblucihttp，**不含任何 Web 服务器**。
带服务器的是集合 `luci-light`：

```
feeds/luci/collections/luci-light/Makefile
    LUCI_DEPENDS := ... +uhttpd +uhttpd-mod-ubus
```

**修法**：选 `luci-light`，让依赖把 uhttpd 和 uhttpd-mod-ubus 带进来。
不要只手写 `CONFIG_PACKAGE_uhttpd=y` —— 那样 uhttpd-mod-ubus 不来，
LuCI 的 ubus RPC 仍然不通。

---

## 4. `flow_offloading` 导致整个防火墙规则集加载失败

**现象**：PC ping 不通设备，LuCI 打不开，但设备端服务全在跑
（uhttpd、rpcd、dropbear 都监听 0.0.0.0）。

**根因**：

```
/dev/stdin:225:29-44: Error: Could not process rule: Protocol error
        meta l4proto { tcp, udp } flow offload @fb;
                                  ^^^^^^^^^^^^^^^^
The rendered ruleset contains errors, not doing firewall restart.
```

fw4 放弃加载，只留下一个残缺的主链：

```
chain input {
    type filter hook input priority filter; policy drop;
    iif "lo" accept
    ct state vmap { ... }
    tcp flags ... jump syn_flood
    jump handle_reject          ← 没有 iifname "br-lan" jump input_lan
}
```

**所有入站流量被丢弃**，包括 LuCI 的 80 端口和 SSH 的 22 端口。

**修法**：

```
uci set firewall.@defaults[0].flow_offloading=0
uci set firewall.@defaults[0].flow_offloading_hw=0
uci commit firewall
/etc/init.d/firewall restart
```

修好后 `chain input` 里出现 `iifname "br-lan" jump input_lan`。

---

## 5. `rfc1918_filter` 让 LuCI 返回 403

**现象**：`http://192.168.1.1/` 返回 200，但
`/cgi-bin/luci/` 返回 403。静态文件（`cascade.css`）却正常 200。

**根因**：uhttpd 默认 `rfc1918_filter 1`，这是防 DNS-rebinding 的措施，
拒绝「私网源地址访问私网目标」。路由器的唯一地址就是私网，所以
所有 LAN 客户端都被拒绝。

设备上手动跑 `/usr/bin/ucode /www/cgi-bin/luci` 可以看到：

```
Status: 403 Forbidden
x-luci-login-required: yes
```

**修法**：

```
uci set uhttpd.main.rfc1918_filter=0
uci commit uhttpd
/etc/init.d/uhttpd restart
```

---

## 6. `identity` 分区全 0xFF，MAC 全是随机值

**现象**：

```
GDM1 has no usable MAC, using 6e:21:0f:24:de:94
eth0 lan2 lan3 lan4 全是这个地址
airoha-xpon: ignoring invalid default PON serial (8 bytes)
```

**根因**：DTS 从 `identity` 分区读 nvmem cell：

```
fh_base_mac   @0x00  6 B   -> gdm1
fh_lan_mac    @0x06  6 B   -> gdm3 (lan1)
fh_pon_serial @0x0c  8 B   -> pon-serial
fh_pon_mac    @0x14  6 B   -> gdm2 (pon0)
```

但该分区在出厂状态全是 0xFF。真实值在 `factory` UBI 卷
（`ubi0_0`，挂到 `/factory`）的 `factory_conf` 里：

```
brmac         24:E3:A4:96:2F:20
eth1mac       24:E4:A4:96:2F:41
eth2mac..4    24:E4:A4:96:2F:42..44
ponmac        24:E3:A4:96:2F:20
SerialNumber  3085224E3A4962F20
```

**修法**：把真实值按 DTS 的 26 字节布局写进 `identity` 分区。
写完后 MAC 立刻变成真实值，PON serial 警告消失。

---

## 7. `eth1mac` 的 OUI 与驱动约束冲突（未彻底解决）

**现象**：

```
airoha_eth 1fb50000.ethernet: eth1: wrong mac addr, MSBs must be 24:e3:a4
```

**根因**（`airoha_eth.c` 的 `airoha_set_macaddr`）：
同一个控制器上所有 GDM 的高 3 字节必须一致，否则拒绝。
但厂商给 `eth1mac` 的是 `24:E4:A4`，与 `brmac` 的 `24:E3:A4` 不同 ——
**厂商自己的数据违反了厂商自己的驱动约束**。

**当前处理**：`fh_lan_mac` 改用 `brmac` 末字节 +1
（`24:E3:A4:96:2F:21`），与其他 GDM 同 OUI。
代价是放弃了厂商给 lan1 的 `24:E4:A4:...:41`。

**待定**：也可以改驱动放宽这条校验。权衡中。

---

## 8. `mtd6` 有一个 ECC 不可纠正的擦除块，jffs2 无法挂载

**现象**：某次重启后主机名变成 `root@(none)`、root 密码丢失、
所有配置回默认。

```
jffs2: cannot read OOB for EB at 020e0000, requested 8 bytes, read 8 bytes, error -74
mount_root: failed to mount -t jffs2 /dev/mtdblock6 /tmp/overlay: I/O error
```

**定位**：`-74` = `EBADMSG`（ECC 不可纠正）。

- `mtd6` 的 offset `0x020e0000` = 第 263 个擦除块
- 单独读第 263 块 → `ecc_failures` 从 1 增到 2（**确认就是这块**）
- 读第 262、264 块 → 计数不变（邻居正常）
- `bad_blocks = 0` —— NAND 的坏块表里没记录，属于
  「ECC 不可纠正但未标记坏块」

**jffs2 不支持跳过坏块**，所以整块分区不可用。
手动 `mtd erase` 后能挂一次，写入后 ECC 再次失败。

**这就是 overlay 反复丢失、配置不持久的真正原因。**

### 待实施的修法

`fstools` 的 `mount_root.c` 支持命令行覆盖：

```c
char *dataname = "rootfs_data";
if (get_var_from_file("/proc/cmdline", "fstools_overlay_name", dataparam, ...))
```

所以可以：

1. DTS 里把 `partition@7f00000`（72 MiB，物理 mtd8）的 `label`
   从 `rootfs_data` 改成别的名字，比如 `overlay`
2. bootargs 加 `fstools_overlay_name=overlay`

**已验证 mtd8 干净**：擦除后 `mount -t jffs2 /dev/mtdblock8` 返回 0，
`ecc_failures = 0`。

另一个选项是改用 UBI（UBI 自带坏块管理），但改动面大得多。

---

## 9. 其他观察（暂不处理）

| 项 | 现象 | 影响 |
| --- | --- | --- |
| cpufreq | `airoha-cpufreq: probe failed with error -2` | 无法调频，跑默认频率 |
| thermal | `No trip points found for thermal id=1/2` | 无过热保护 |
| PHY LED | `mdio_bus mt7530-0: Failed to setup PHY LED pinctrl` ×3 | 网口灯可能不亮 |
| PON 模式 | `mode=xgpon`，但线路是 GPON | **PON 无法同步（见下）** |

---

## 10. PON 无法同步：驱动缺 GPON 实现（功能缺口，非 bug）

**现象**：无限重试，recovery 计数一直增长：

```
airoha-xpon: optical signal present without XGTC sync;
             running short PMA recovery (recovery 441)
airoha-xpon: XG-PON RX started, irq=29, ONU-ID=1023 (invalid),
             burst TX remains disabled
```

**根因**：`airoha-xpon` 驱动只有 `airoha-xpon-epon.c` 和
`airoha-xpon-xgpon.c`，**没有 GPON 实现**。
`mode=gpon` 会直接返回 `-EOPNOTSUPP`。
驱动默认 XG-PON（`airoha-xpon-mode.c:118`）。

本机是 GPON ONU（`pon_mode=2`，`GponSN=46485454C255B8F9`），
所以永远同步不上。

**这不是配置问题，是上游驱动缺少功能。** 需要自己实现 GPON 支持。
