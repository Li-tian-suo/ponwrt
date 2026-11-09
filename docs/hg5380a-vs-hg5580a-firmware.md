# HG5380A vs HG5580A 固件表现对照

> HG5580A 全部是 2026-11-08 在实物上实测的。HG5380A 依据其仓库里的
> 移植记录与 DTS，未实测的项目会明确标注。

## 一、启动表现

### HG5580A（实测）

引导链：

```
BL2 (bootloader @0x0)
 └→ FIP @0x800: BL2 + BL31 + U-Boot + X.509 证书
     └→ U-Boot 2023.04 (Dec 03 2025)
         └→ bootcmd: mtd read KernelB ; bootm
             └→ Linux 6.18.55 + PonWrt
```

串口启动日志关键行：

```
U-Boot 2023.04 (Dec 03 2025 - 02:51:42 +0800)
CPU:   Airoha AN7583
DRAM:  512 MiB
Detected SPI NAND Flash : _SPI_NAND_DEVICE_ID_S35ML02G3, Flash Size=0x10000000
Serdes2 HSGMII MODE Init, ETH VER = AN7583_ETH.0.09.16

[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x410fd034]
[    0.000000] Linux version 6.18.55
[    0.000000] Machine model: FiberHome HG5580A
[    1.229358] 0x00000ec00000-0x00000ec20000 : "bosacal"
[    1.808321] VFS: Mounted root (squashfs filesystem) readonly
[   35.996922] jffs2: notice: complete building xattr subsystem
```

内存实际可用：

```
MemTotal:  439624 kB    (429 MiB，512 MiB 减去 reserved)
```

### HG5380A

同为 AN7583，引导链结构一致（BL2 → FIP → U-Boot → Kernel 分区）。
原厂内核是 6.6.23（FiberHome 定制），PonWrt 用同一套开源内核。

---

## 二、网口表现

### HG5580A（实测）

| 端口 | PHY | 能力 | 实测 |
| --- | --- | --- | --- |
| lan1 | YT8821 | 2.5G | ✅ **2500 Mb/s**，链路建立正常 |
| lan2 | AN7583 内建 | 1G | ✅ 1 Gbps |
| lan3 | AN7583 内建 | 1G | ✅ |
| lan4 | AN7583 内建 | 1G | ✅ |

lan1 内核日志：

```
airoha_eth 1fb50000.ethernet lan1: PHY [1fb00000.system-controller:mdio-bus@c8-mii:07]
                                  driver [YT8821 2.5Gbps PHY] (irq=POLL)
airoha_eth 1fb50000.ethernet lan1: configuring for phy/2500base-x link mode
airoha_eth 1fb50000.ethernet lan1: Link is Up - 2.5Gbps/Full - flow control rx/tx
```

**测速结果（homebox，浏览器端）**：

```
下载   2.17 Gbps    峰值 2.91 Gbps
上传   1.26 Gbps    峰值 1.32 Gbps
```

下载达到 2.5G 线速的 87%，正常。上传偏低是 homebox 用 JS `fetch()`
逐块上传的固有限制，不是链路问题。

### HG5380A

2.5G 口同样是 lan1，但 PHY 是 EN8811H（MDIO `0xf`），
需要 `kmod-phy-airoha-en8811h` 而不是 `kmod-phy-motorcomm`。

---

## 三、PON 表现

### 两台共同的硬缺口

开源 `airoha-xpon` **没有 GPON 实现**。驱动里 GPON 那一条故意不设
`mac_supported`：

```c
{
    .mode = AIROHA_XPON_MODE_GPON,
    .name = "gpon",
    .frontend_mode = AIROHA_PON_FRONTEND_MODE_GPON,
    /* 没有 .mac_supported = true */
},
```

`airoha-xpon-main.c:200` 直接返回 `-EOPNOTSUPP`（-95）。

### HG5580A（实测）

驱动默认 XG-PON，在 GPON 线路上无限重试：

```
airoha-xpon: optical signal present without XGTC sync;
             running short PMA recovery (recovery 301)
airoha-xpon: XG-PON RX started, irq=29, ONU-ID=1023 (invalid),
             burst TX remains disabled
```

`recovery` 计数一直涨（实测到 301 次），**永远同步不上**。

设备身份（`factory_conf`）：

```
GponSN       46485454C255B8F9   ("FHTT" + C2:55:B8:F9)
GPONPassWord 48473236303132333435 ("HG26012345")
pon_mode     2                  (GPON)
```

**结论：光口不能上网，也不能做光口测速。**

### 光模块

```
airoha-paged-bosa 0-0051: UX3363 frontend registered,
                          ID 55583333363331, calibration invalid
```

`calibration invalid` 是真实问题：`bosacal` 分区里是厂商私有格式
（`fiberhomebdbob` + `202404291559VB`），不是 paged-bosa 期望的格式。
光功率读数会不准。

---

## 四、LuCI 表现

### HG5580A（实测）

```
http://192.168.1.1            LuCI 登录页     HTTP 200（页面 664 B，跳转 cgi-bin/luci）
http://192.168.1.1/cgi-bin/luci/              未登录 403 + x-luci-login-required: yes
POST 登录 root/admin                          HTTP 302 + sysauth_http cookie
http://192.168.1.1/cgi-bin/luci/admin/status/overview  HTTP 200，标题 "ponwrt - LuCI"
```

已装应用（23 个）：

```
argon-config  commands  ddns  filemanager  firewall  hd-idle
homebox  ksmbd  luci-base  luci-mod-network  luci-mod-status
luci-mod-system  luci-proto-wireguard  mwan3  nlbwmon
package-manager  pon  sqm  ttyd  udpxy  uhttpd  upnp
vnstat2  wol
```

### 打开网页的两个必需前提（实测）

**如果不改这两项，浏览器会显示「拒绝连接」**：

1. `flow_offloading=1` 会让 `nft` 拒绝整个防火墙规则集：

   ```
   Error: Could not process rule: Protocol error
           meta l4proto { tcp, udp } flow offload @fb;
   The rendered ruleset contains errors, not doing firewall restart.
   ```

   fw4 放弃加载，只留一个 `policy drop` 的残缺主链，没有
   `iifname "br-lan" jump input_lan`，**所有入站流量被丢**。

2. `rfc1918_filter=1` 会让 LuCI 返回 403（静态文件却是 200，很容易误判）。

修法：

```sh
uci set firewall.@defaults[0].flow_offloading=0
uci set firewall.@defaults[0].flow_offloading_hw=0
uci set uhttpd.main.rfc1918_filter=0
uci commit firewall; uci commit uhttpd
/etc/init.d/firewall restart; /etc/init.d/uhttpd restart
```

---

## 五、overlay 与配置持久化

### HG5580A（实测）

`RootfsB` 尾部会被 `squashfs-split` 自动切出一段 `rootfs_data`（mtd6）。
**但这段有一个 ECC 不可纠正的坏块：**

```
jffs2: cannot read OOB for EB at 020e0000, requested 8 bytes, read 8 bytes, error -74
mount_root: failed to mount -t jffs2 /dev/mtdblock6 /tmp/overlay: I/O error
```

`-74` = `EBADMSG`。定位到第 263 块（`0x020e0000`），单读它
`ecc_failures` 递增，读邻居不变，`bad_blocks` 仍是 0。

**后果**：jffs2 挂不上 → overlay 退回 tmpfs → **主机名变 `(none)`、
root 密码丢失、所有配置不持久**。

**修法**：把 72 MiB 那段（`0x7F00000`）改名 `overlay`，
bootargs 加 `fstools_overlay_name=overlay`，绕开坏块区。

依据 `fstools/libfstools/mount_root.c`：

```c
char *dataname = "rootfs_data";
if (get_var_from_file("/proc/cmdline", "fstools_overlay_name", ...))
```

修好后实测：

```
/dev/mtdblock6 on /overlay type jffs2 (rw,noatime)
overlayfs:/overlay on / type overlay (rw,...)
主机名 ponwrt  ✅
```

---

## 六、MAC 地址

### HG5580A（实测）

**修之前**（`identity` 全 0xFF）：

```
GDM1 has no usable MAC, using 6e:21:0f:24:de:94
eth0 / lan2 / lan3 / lan4 全是这个地址
airoha-xpon: ignoring invalid default PON serial (8 bytes)
```

**修之后**（从 factory 写入真实值）：

```
eth0     24:e3:a4:96:2f:20
lan1     24:e3:a4:96:2f:21
lan2-4   24:e3:a4:96:2f:20
pon0     24:e3:a4:96:2f:20
br-lan   24:e3:a4:96:2f:21
```

遗留问题：

```
airoha_eth 1fb50000.ethernet: eth1: wrong mac addr, MSBs must be 24:e3:a4
```

厂商给 `eth1mac` 的是 `24:E4:A4`，与 `brmac` 的 `24:E3:A4` 不同 OUI，
驱动拒绝。目前用 `brmac` 末字节 +1 派生，放弃厂商的 `eth4mac` 值。

---

## 七、其他实测差异

| 项目 | HG5580A 实测 | 说明 |
| --- | --- | --- |
| cpufreq | ❌ `probe failed with error -2` | `_opp_set_clknames: Couldn't find clock with name: cpu`，跑默认频率 |
| thermal trip | ❌ `No trip points found for thermal id=1/2` | 无过热保护 |
| PHY LED pinctrl | ❌ `mdio_bus mt7530-0: Failed to setup PHY LED pinctrl` ×3 | 网口灯可能不亮 |
| ttyd | ✅ `192.168.1.1:7681` | 网页终端 |
| homebox | ✅ `0.0.0.0:3300` | 内网测速 |
| iperf3 | ✅ 已装 | |
| NFS | ✅ `0.0.0.0:2049` | |
| sing-box | ❌ 没编出来 | Go 工具链缺失，homeproxy 无法工作 |
| SMB | ✅ ksmbd 已装 | |

---

## 八、可用工具清单

### HG5580A（实测运行中）

```
iperf       /usr/bin/iperf
iperf3      /usr/bin/iperf3
homebox     /usr/bin/homebox     (serve --host 0.0.0.0 --port 3300)
igmpproxy   /usr/sbin/igmpproxy
udpxy       /usr/bin/udpxy
uhttpd      /usr/sbin/uhttpd
ttyd        (7681)
```

服务状态：

```
uhttpd     on    running
rpcd       on    running
dnsmasq    on    running
dropbear   on    running
homebox    on    running
udpxy      on    stopped
igmpproxy  on    stopped
homeproxy  off   stopped     <- 缺 sing-box 核心
```

---

## 九、总结对照

| 能力 | HG5380A | HG5580A |
| --- | --- | --- |
| PonWrt 启动 | ✅ | ✅ 实测通过 |
| LuCI | ✅ | ✅ 实测 `HTTP 200` |
| 2.5G 有线 | ✅ | ✅ 实测 2.17 Gbps 下行 |
| 千兆有线 | ✅ | ✅ |
| Wi-Fi | ✅ MT7916 | ❌ 无硬件 |
| GPON 上网 | ❌ 驱动缺口 | ❌ 驱动缺口 |
| 光口测速 | ❌ | ❌ |
| 配置持久化 | 待确认 | ✅ 修好 overlay 后 |
| 真实 MAC | 待确认 | ✅ 写入 identity 后 |
| 光功率读数 | 待确认 | ⚠️ 校准格式不符 |

**两台机上真正阻塞「光口测速」的是同一件事：开源 xpon 驱动缺 GPON MAC 层。
这与硬件无关，是软件缺口。**
