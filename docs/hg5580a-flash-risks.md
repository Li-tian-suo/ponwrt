# HG5580A 刷机影响与风险

> 只写实测过的，不确定的会标出来。

## 一、刷机动了什么，没动什么

### 会写入的分区

| 分区 | 偏移 | 大小 | 写入内容 |
| --- | --- | --- | --- |
| `KernelB` | 0x3100000 | 6 MiB | 裸 FIT（内核 + DTB） |
| `RootfsB` | 0x3700000 | 40 MiB | squashfs 根文件系统 |

### 完全不碰的分区

| 分区 | 内容 | 后果 |
| --- | --- | --- |
| `bootloader` | BL2 + BL31 + U-Boot + X.509 | 写坏只能上编程器 |
| `bootflag` | 启动标志 | 只由 `fhbootflag` 命令改 |
| `KernelA` / `RootfsA` | 原厂固件 | **保持完好，随时可回退** |
| `factory` | UBI 卷：MAC、序列号、光模块型号 | 唯一副本 |
| `identity` | MAC / PON 序列号（出厂全 0xFF） | 我们写入真实值 |
| `bosacal` | 光模块校准 | 丢了光功率读数不准 |
| `frameworka/b` | 原厂应用区 | 未使用 |

**A 槽全程不动，这是回退能力的基础。**

---

## 二、可以完全回退的改动

### 2.1 bootcmd（存在 SPI-NAND 环境区）

```sh
# 改成 PonWrt 启动
setenv bootcmd "mtd read KernelB 0x88000000 0x0 0x600000; bootm 0x88000000"
saveenv

# 回到原厂
setenv bootcmd "ldkernel;bargsenv;bootm"
saveenv
```

`saveenv` 写的是 SPI-NAND 的环境区，不是 bootloader 镜像。

### 2.2 启动槽标志

```sh
fhbootflag set 0 0 0 0     # 从 A 槽启动（原厂）
fhbootflag set 1 1 1 1     # 从 B 槽启动（PonWrt）
```

⚠️ **不要用 `bootflag swap`**：它把四个 flag 全部翻转（0→1），
会把设备指向 B 槽。如果 B 槽是坏镜像，设备就起不来了。

实测 `bootflag read` 的语义：

```
current bootflag=0   -> A 槽
current bootflag=1   -> B 槽（具体看四个 flag 的组合）
```

### 2.3 identity 分区

出厂是**全 0xFF**，所以内核读到 `ff:ff:ff:ff:ff:ff`，判为无效，
回退到随机 MAC。我们从这个位置写入真实值：

```
偏移      长度   内容              来源
0x00      6 B    基础 MAC          factory_conf/brmac
0x06      6 B    lan1 MAC          brmac 末字节 +1
0x0c      8 B    PON 序列号        factory_conf/SerialNumber
0x14      6 B    PON MAC           factory_conf/ponmac
```

**原始状态（全 0xFF）是可恢复的**：擦一次就回到出厂状态。

```
mtd erase identity
```

代价是 MAC 又变随机。

### 2.4 overlay 分区（72 MiB）

这段在厂商分区表里属于 `apps`（`0x5f00000..0xc700000` 104 MiB）的后半部分。
里面原本是厂商的 UBI 数据卷（开头 `UBI#`，实测约 15.4 MiB 真实数据）。

刷机时擦了它给 PonWrt 做 overlay。**内容已完整备份**：

```
backup/rootfs_data.bin    75,497,472 B
```

按每块设备（128 KiB）的 CRC32 逐个偏移验证过，288 个偏移全部吻合。

---

## 三、真实存在的风险

### 3.1 NAND 有物理坏块

擦除 RootfsB 时实测报错：

```
[spinand_ecc_fail_check] : ECC cannot recover detected !, page=0xbd80
spi_nand_read_page: Bad Block, ECC cannot recovery detecte, page=0xbd80
Read erase block counter 0x2f6 fail.
```

`0xbd80 × 0x800 = 0x5EC0000`，位于 RootfsB 分区尾部（rootfs 只写到 `0x2293800`）。

**本次不影响**：写入后回读 CRC 一致（`0x8e0acb0c`）。

**但风险在**：这块 NAND 的坏块会随写入次数增加。如果哪天坏块蔓延到
rootfs 数据区，squashfs 就读不出来了。

**缓解**：保留好 `rootfsB.bin`，随时能重刷。

### 3.2 原厂 sysupgrade 会变砖

`target/linux/airoha/an7583/base-files/lib/upgrade/platform.sh` 里
没有 `fiberhome,hg5580a` 分支，会落到 `nand_do_upgrade`：

```sh
# 它要求这些 UBI 卷存在
ubi_volume_exists fip
ubi_volume_exists ubootenv
ubi_volume_exists ubootenv2
```

本机这三个卷**都不存在**（KernelA/B、RootfsA/B 都是裸分区），
执行会把设备写坏。

**所以：绝对不要在 PonWrt 里跑 `sysupgrade`。**

要更新固件只能走 U-Boot 手工刷（见 `hg5580a-uboot-flash-guide.md`）。

### 3.3 厂商固件签名校验，ldkernel 走不通

`ldkernel` 会加载三段 X.509 证书并校验固件内容签名：

```
id  7   Trusted Key Certificate                  2,574 B
id 11   Non-Trusted Firmware Key Certificate     2,026 B
id 15   Non-Trusted Firmware Content Certificate 1,666 B
```

我们没私钥，签不了名。实测卡在 `Loading image id=11` 之后，串口无输出。

**所以必须改 bootcmd 绕过 ldkernel。**

### 3.4 U-Boot 的 PHY 只支持 100M

U-Boot 里 `mii info 7` 显示 `100baseT, FDX`。PC 网卡如果自动协商到
2.5G/1G，TFTP 完全不通。

**刷机期间必须把 PC 网卡固定 100M**，刷完改回自动侦测。

### 3.5 不可逆的损失

| 项 | 能否恢复 |
| --- | --- |
| A 槽原厂固件 | ✅ 没动过 |
| bootloader | ✅ 没动过 |
| factory 数据 | ✅ 没动过 |
| rootfs_data 里的厂商 UBI 卷 | ✅ 有完整备份 |
| identity 原始值（全 0xFF） | ✅ 擦掉即可 |
| NAND 磨损 | ❌ 每次写入都消耗寿命 |

---

## 四、原厂固件与 PonWrt 的功能对比

### PonWrt 能做的

| 功能 | 状态 |
| --- | --- |
| 2.5G 有线（lan1） | ✅ 实测 2.17 Gbps 下行 |
| 千兆有线（lan2/3/4） | ✅ |
| LuCI 网页管理 | ✅ |
| SSH | ✅ |
| 内网测速（homebox） | ✅ |
| iperf3 | ✅ |
| IPTV 组播（igmpproxy + udpxy） | ✅ 已装，未实测 |
| 透明代理（homeproxy） | ⚠️ 界面在，sing-box 核心没编出来 |
| 网页终端（ttyd） | ✅ |
| SMB / NFS 共享 | ✅ 已装 |

### PonWrt 做不到的

| 功能 | 原因 |
| --- | --- |
| **GPON 上网** | 驱动缺 GPON MAC 实现，见下 |
| Wi-Fi | 本机无 WLAN 硬件（5380A 才有 MT7916） |
| 原厂 TR-069 远程管理 | 厂商私有实现 |
| 原厂语音（VoIP） | 厂商私有实现 |
| 原厂 APP 联动 | 厂商私有实现 |

### GPON 是硬缺口

`airoha-xpon` 驱动只有 EPON 和 XG-PON 实现，**没有 GPON**：

```c
/* airoha-xpon-mode.c */
{
    .mode = AIROHA_XPON_MODE_GPON,
    .name = "gpon",
    .frontend_mode = AIROHA_PON_FRONTEND_MODE_GPON,
    /* 故意不设 .mac_supported = true */
},
```

启动路径直接拒绝（`airoha-xpon-main.c:200`）：

```c
if (!mode || !mode->mac_supported || ...) {
    ret = -EOPNOTSUPP;      /* = -95 */
    goto out_unlock;
}
```

所以光口一直处于这个状态：

```
airoha-xpon: optical signal present without XGTC sync;
             running short PMA recovery (recovery 301)
```

**光口测速做不到**，除非自己实现完整的 GTC 层（数千行）。
详见 `docs/hg5580a-gpon-feasibility.md`。

---

## 五、刷机后必须做的两处配置

网页打不开不是 LuCI 的问题，是两个默认值：

```sh
# 1) flow_offloading 会让 nft 拒绝整个规则集
#    -> fw4 放弃加载，只留 policy drop 的残缺主链
#    -> 所有入站流量被丢，80 端口拒绝连接
uci set firewall.@defaults[0].flow_offloading=0
uci set firewall.@defaults[0].flow_offloading_hw=0

# 2) rfc1918_filter 拒绝「私网源访问私网目标」
#    -> 路由器唯一地址就是私网，所有 LAN 客户端被 403
uci set uhttpd.main.rfc1918_filter=0

uci commit firewall
uci commit uhttpd
/etc/init.d/firewall restart
/etc/init.d/uhttpd restart
```

板级默认值应该放进
`target/linux/airoha/an7583/base-files/etc/uci-defaults/`，
但**实测这个目录下的脚本没进镜像**（`ls /etc/uci-defaults/` 为空），
所以目前只能手工改。
