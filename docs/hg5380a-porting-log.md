# FiberHome HG5380A 移植日志（Airoha AN7583 / XG-PON）

> 目标：把 PonWRT（OpenWrt 派生，ImmortalWrt 内核 6.18 分支）移植到烽火 HG5380A。
> 本文是按时间顺序的完整适配记录，含踩过的坑、验证数据和可复现步骤。
> 最后更新：2026-11-04

---

## 一、设备概况

| 项目 | 规格 |
|---|---|
| SoC | Airoha AN7583（2× Cortex-A53 @ 1.0 GHz，无 WiFi） |
| 内存 | 512 MiB DDR |
| 存储 | FORESEE F35SQB002G，256 MiB SPI-NAND |
| 光口 | XG-PON（XGTC），BOSA UX3363（i2c0 0x51，paged） |
| LAN1 | 2.5G，Motorcomm YT8821（MDIO 0x07，PHY ID `0x4f51ea19`） |
| LAN2~4 | 交换芯片内部 PHY（无端口灯） |
| 按键 | 复位键 GPIO35（低有效） |
| LED | 光信号灯 GPIO33（低有效）；光宽带为 PWM 通道 10；电源灯硬件常亮 |
| 运营商 | 湛江电信，XG-PON，签约 1000/50 |

### 分区布局（内核视角 13 个 mtd）

| 偏移 | 大小 | 分区 | 用途 |
|---|---|---|---|
| 0x0000000 | 2.5 MiB | bootloader (mtd0) | **绝对不碰** |
| 0x0280000 | 512 KiB | bootflag (mtd1) | U-Boot 环境 |
| 0x0300000 | 6 MiB | KernelA (mtd2) | 原厂内核 |
| 0x0900000 | 40 MiB | RootfsA (mtd3) | 原厂根 |
| 0x3100000 | 6 MiB | KernelB (mtd4) | **OpenWrt 内核 FIT** |
| 0x3700000 | 40 MiB | RootfsB (mtd5) | 已弃用（尾部有坏块） |
| 0x5F00000 | 32 MiB | apps (mtd6) | **squashfs 根** |
| 0x7F00000 | 72 MiB | rootfs_data (mtd7) | **ext4 持久化** |
| 0xC700000 | 16 MiB | frameworka (mtd8) | 原厂 |
| 0xD700000 | 16 MiB | frameworkb (mtd9) | 原厂 |
| 0xE700000 | 5 MiB | factory (mtd10) | **原厂数据，只读** |
| 0xEC00000 | 128 KiB | bosacal (mtd11) | BOSA 校准 2048 字节 |
| 0xEC20000 | 128 KiB | identity (mtd12) | MAC / PON SN，26 字节 |

板级信息来自内嵌 DTB（`/sys/firmware/fdt`），**不是**原厂 DTB 文件。

---

## 二、阶段一：能引导、能进系统

### 2.1 设备树

从 `airoha/an7583` 子目标新增 `an7583-fiberhome-hg5380a.dts`，主要差异：

- 内存 512 MiB、SPI-NAND（snfi）启用
- 2.5G PHY 从 EN8811H 改为 **Motorcomm YT8821 @ 0x07**
- 光模块从 EN7572 改为 **UX3363 paged BOSA @ 0x51**
- 按键/LED 引脚按实测修正（见阶段三）
- **删除 OPP 表引用**（见 2.3）

### 2.2 内核镜像格式

原厂 U-Boot 的 lzma 解码器不接受 `lp=2` 的流，内核必须 **gzip** 压缩：

```
CONFIG_KERNEL_GZIP=y
```

### 2.3 cpufreq 会让 6.18 panic

`dt_cpufreq` 解析本 SoC 的 OPP 表时崩在
`_of_add_table_indexed → dev_pm_opp_of_cpumask_add_table → strcmp`（野指针）。

- 修法：DTS 里对 `cpu0/cpu1/cpufreq` 做 `/delete-property/ operating-points-v2`，
  并把 `cpufreq` 节点设 `status = "disabled"`。
- 注意 `CONFIG_ARM_AIROHA_SOC_CPUFREQ` 会 `select CPUFREQ_DT`，
  **`# CONFIG_x is not set` 关不掉**，只能从 DTS 侧断。
- 代价：CPU 跑在默认频率，空闲温度 77–79 °C，建议加散热片。

### 2.4 踩过的 PHY 坑（按提交顺序）

这一段走了最长的弯路，因为原厂 cmdline 里的 `8811phy_addr`、
`srdsEtherPhyTypeAllComp` 都是 EVB 遗留，误导了很久。

| 提交 | 试过什么 | 结果 |
|---|---|---|
| `52c0309` | 关闭 AN7583 NPU | ✅ NPU probe 会把启动卡死 |
| `5880a28` / `a02c49f` | 在 0x0d/0x0e/0x0f 上探 EN8811H、灌固件 | ❌ 全部无效 |
| `e189ecd` | 照抄 Nokia XG-040G-MF 的 EN8811H 设置（GPIO34 复位、单 PHY） | ❌ |
| `b987946` / `25c8a21` / `0a6e980` | 强制 C45、C22 间接窗口、unlocked 访问器 | ❌ |
| `1de13af` / `b2c4611` | 只留固件加载诊断、验证 PBUS 写入是否真的落地 | ❌ |
| `6c33b2c` | EN7572 → 0x51 paged BOSA，PHY 改回 0x0f，启用 eth_pcs | ❌ |
| **`d3e0d29`** | **2.5G PHY 其实是 YT8821 @ 0x07** | ✅ **2.34 Gbps** |

其它同期修复：

- `7e1e28e`：`mdio0` 引脚被声明两次 → 交换芯片 probe 直接失败
- `2d4559c`：必须启用 `gdm1`（交换芯片 CPU 口），DSA 会等它
- `7a3e83c`：`spi-nand` ID 表加入 **FORESEE F35SQB002G**
- `f93a9d8`：`board.d` 识别 `fiberhome,hg5380a`

---

## 三、阶段二：LED、按键、开关机灯

### 3.1 定位复位键：GPIO35

原厂 DTB 写的是 GPIO0，实际是 **GPIO35**。

定位方法：把 0..38 全部挂成 `gpio-keys` 探针（label `k00`..`k38`），按一次键看
`/proc/interrupts` 里哪个 label 的计数增长。

> ⚠️ `gpio-keys` 是**整体设备**，任一子节点取的引脚冲突都会导致整个设备 probe 失败。
> 所以必须避开已被占用的引脚（PON 15~20、按键 35）。

### 3.2 内核 `CONFIG_INPUT is not set`

内核通用配置里 `CONFIG_INPUT` 是关的，`gpio-keys` 和 `gpio-button-hotplug`
全是摆设。修法（`target/linux/airoha/config-6.18`）：

```
CONFIG_INPUT=y
```

同时必须关掉内核自带的 `KEYBOARD_GPIO`，否则会和 `gpio-button-hotplug`
抢同名驱动：`Driver 'gpio-keys' is already registered`。

### 3.3 光信号灯 GPIO33

`green:los`，低有效，trigger `pon0-los`，无光时 `brightness=1`（亮）。

### 3.4 光宽带灯（PWM 通道 10）——两个坑

1. **节点位置**：`pwm-airoha` 驱动用 `device_node_to_regmap(dev->parent)` 取寄存器，
   所以节点必须是 `system-controller@1fbf0200`（syscon）的**子节点，且不能有 `reg`**。
   写在顶层并带 reg → `probe failed with error -12`。
2. **gpio18 冲突**：`pinctrl-an7583.c` 的
   `pon_tx_disable_gpio_pins[] = { 15, 16, 18, 19, 20 }` 包含 gpio18，
   而本机"光宽带"灯正是 gpio18 的 PWM 通道 10。
   **绝对不能用删 `&xpon_mac { pinctrl-0 = <&pon_pins> }` 的办法绕过**——
   撤掉引脚复用后 PON 接收引脚浮空，会产生**假光信号**，驱动无限 recovery。
   正确做法是给 pinctrl 驱动打补丁把 18 从该组摘掉。

### 3.5 网络灯

无 GPIO 能点亮，推测由交换芯片 PHY LED 输出驱动。暂不处理。

---

## 四、阶段三：持久化

**jffs2 在这颗 SPI-NAND 上不可能工作**（OOB 全被 ECC 占用）。

方案：`rootfs_data`(mtd7) 上建 ext4，bind 关键路径。

```
/etc/config      ← 配置
/etc/dropbear    ← SSH host key
/root            ← root 家目录
```

> ⚠️ **不能 bind 整个 `/etc`**：会把 `/etc/init.d`、`/etc/rc.d` 盖住，
> 除 S05 外所有服务都不会启动。

### 4.1 `passwd` 报 "Cross-device link"

早期把 `/etc/shadow`、`/etc/passwd` 也 bind 了，导致：

```
passwd: can't create backup copy '/etc/shadow-': Cross-device link
passwd: can't update password file /etc/shadow
```

修法：**不再 bind 这两个文件**，改成开机从 persist 复制、定期回写。

---

## 五、阶段四：PON 物理层注册（O5）

### 5.1 模式切换与 autoprobe

原厂默认是 xgpon，但调试期曾误切到 gpon。提供运行时切换：

```
/usr/bin/pon-mode xgpon|gpon     # 走 line_mode debugfs
/usr/bin/autoprobe               # 开机自动判断
```

> ⚠️ **autoprobe 的假阳性**：早期实现判断条件是"不是 hunt 就算成功"，
> 但 gpon 模式的 debugfs 里**根本没有 `xgtc_sync` 字段**，于是永远判成功。
> 必须改成要求 `xgtc_sync: in-sync`。

### 5.2 首次接入真实 OLT：XG-PON 一次通过

```
configured_mode: xgpon
lifecycle: operational
optical_signal: 1
xgtc_sync: in-sync          ← XGTC 帧锁定
onu_state: O5               ← 最高状态 operational
onu_id: 153                 ← OLT 分配的 ID（不再是 1023）
rx_power_8472: 0x015e       ≈ -14.6 dBm
tx_power_8472: 0x5649       ≈ +3.4 dBm
```

内核日志：

```
PLOAM: absolute EqD=0x00066464; entered O5; service GEM/T-CONT mapping is still required
PLOAMd: dest=153, msg-id=0x04 ... result=0        ← Assign_Alloc_ID 被接受
Key_Control received: seq=2 generate → Key_Report sent
Key_Control received: seq=3 confirm  → Key_Report sent
```

**结论：BOSA → SerDes → PLOAM → O5 全链路打通，用的是原厂 SN（FHTT C1F0BA75）。
运营商没有做额外绑定，模式也不需要改成 GPON。**

---

## 六、阶段五：OMCI 业务下发（最难的一段）

### 6.1 卡点现象

```
rx_active: 1
upstream_tx_armed: 1
channel_0_rx_packets: 81     ← OMCI 报文已经收到
data_path_configured: 0      ← 没人处理
service_ready: 0
```

内核驱动把 OMCI 报文导出到 `omci0` / `oam0` 原始接口，需要用户态守护进程
`airoha-pond`（Rust）处理 MIB Upload / Create / Set / Get，并建立
T-CONT / GEM port / VLAN 映射。没有它就没有 `service_ready`，pon0 不会 carrier up。

### 6.2 编译 airoha-pond 踩的坑

| 问题 | 修法 |
|---|---|
| `~/.wgetrc`、`~/.curlrc` 里有失效代理 | 清除 |
| `rust` 包没 `feeds install` | `./scripts/feeds install rust` |
| WSL 里没有 `curl` | `apt install curl` |
| rustc 源码包 231 MB 下载慢 | 从 `static.rust-lang.org` 直连，sha256 校验 |
| 自制的 `pondctl` shim 与上游包冲突 | 删除 shim（包自带 `/usr/bin/pondctl → /usr/sbin/airoha-pond`） |

### 6.3 `/etc/config/pon` 必须给 omci 段写 device

```
config omci 'omci0'
    option line 'line0'
    option device 'omci0'
```

缺了会报 `omci control device for line 'line0' is missing`，守护进程拒绝启动。

### 6.4 打通后的状态

```
airoha-pond 运行中，loid_configured=true
authentication_status=1 (accepted)，olt_vendor_id=ZTEG（中兴 OLT）
rx/tx messages 269/269，parse_errors=0
tcont_count=1  gem_port_count=4  vlan_rule_count=8
vlan_ids=[41,45,46]  multicast=[50]
backend_state=applied  active_alloc_id=1032  active_gem_id=1035

data_path_configured=1  service_ready=1
pon0 UP <LOWER_UP>，omci0 UP <LOWER_UP>
内核日志 "data paths mapped: count=4"
```

---

## 七、阶段六：上网（PPPoE）

### 7.1 PPPoE 必须用 `pon0.41`（VLAN 41）

现象：`Timeout waiting for PADS`，`tx_no_mapping` 计数持续增长。

根因：**OMCI 下发的分类规则按 VLAN 匹配 GEM**，直接绑 `pon0`（无标签）的帧
全部被 `tx_no_mapping` 丢弃。

修法：`pon0.41`。

### 7.2 LAN→WAN 不通（"Destination port unreachable"）

防火墙 wan 区域里只有 `wan`/`wan6`，没有 `pppoe`。表现极具误导性：
**路由器自己能上网，但内网机器 ping 外网返回 `Destination port unreachable`**。

```
uci add_list firewall.@zone[1].network='pppoe'
```

### 7.3 结果

```
PPPoE:    pon0.41（VLAN 41）
          local IP 100.64.2.104，对端 100.64.0.1
          DNS 202.96.134.133 / 202.96.128.166
          ping 223.5.5.5 = 16ms，HTTP 200
LAN→WAN:  电脑经路由器 ping 外网 16ms ✓
```

### 7.4 附带解决的 LuCI 问题

**LuCI 403 的真凶是 `rfc1918_filter`**：内网设备访问自己的管理界面时被判为
DNS rebinding 而拒绝。镜像里默认改成 0。

另外老版 uhttpd 配置里的 `list lua_prefix .../sgi/uhttpd.lua` 要删掉——
用的是 ucode 版 LuCI，`/cgi-bin/luci` 直接按 CGI 执行。

### 7.5 minimal 档位缺 luci-light，导致镜像里没有 Web 服务器

**这是 2026-11-09 在实机 `r0-e1921dc` 上才暴露的问题**，云编译与本地编译
都能复现，与硬件无关，纯配置缺陷。

现象（TTL 串口实测）：

```
/etc/init.d/uhttpd: not found
netstat 只有 22(dropbear) 与 53(dnsmasq)，没有 80
/etc/rc.d/ 里没有 S*uhttpd
apk list | grep -E 'uhttpd|luci-light'  → 空
但 apk list | grep -c luci → 16   （前端包齐全）
```

即：**LuCI 的 16 个包全在，唯独没有 Web 服务器。**

根因在 `build-hg5380a.yml` minimal 档位的这一行：

```sh
grep -v '^CONFIG_PACKAGE_[A-Za-z0-9_.-]*=y$' .config > .config.trim
```

它把 `configs/an7583.config` 里所有 `=y` 的包全部清掉，其中就包括
`CONFIG_PACKAGE_uhttpd=y`。之后的追加列表只补了 `luci-base` 与
`luci-mod-*`，但**`luci-base` 的 `LUCI_DEPENDS` 里没有任何 Web 服务器**：

```
# feeds/luci/modules/luci-base/Makefile
LUCI_DEPENDS := +rpcd +rpcd-mod-file +rpcd-mod-luci +rpcd-mod-ucode \
                +cgi-io +ucode +ucode-mod-fs +ucode-mod-log +ucode-mod-uci \
                +ucode-mod-ubus +ucode-mod-html +liblucihttp-ucode
```

真正携带 `+uhttpd +uhttpd-mod-ubus` 的是集合 **`luci-light`**：

```
# feeds/luci/collections/luci-light/Makefile
LUCI_TITLE  := LuCI interface with Uhttpd as Webserver (light)
LUCI_DEPENDS := +luci-app-firewall +luci-mod-admin-full +luci-proto-ppp \
                +luci-theme-bootstrap +rpcd-mod-rrdns \
                +uhttpd +uhttpd-mod-ubus
```

修法：

* minimal 档位追加 `CONFIG_PACKAGE_luci-light=y`
* full 档位在 `configs/hg5380a-packages.config` 追加
  `luci-light` / `luci` / `luci-app-uhttpd`

**不要只手写 `CONFIG_PACKAGE_uhttpd=y`** —— 那样 `uhttpd-mod-ubus`
不会跟着来，LuCI 的 ubus RPC 仍然不通，页面能打开但所有功能都报错。

同时修掉一个被注释吞掉的包：

```
原来： # --- theme ---CONFIG_PACKAGE_luci-theme-argon=y
```

注释和 CONFIG 挤在同一行，CI 用 `grep '^CONFIG_PACKAGE_'` 提取时匹配不到
行首，argon 主题一直没生效。现已拆成两行。另外 `luci-theme-argon` 的
`Provides` 已含 `luci-app-argon-config`，不需要单独选。

### 7.6 2.5G 口：PHY 是 YT8821，不是 EN8811H

早期按 Airoha EN8811H（ID `0x03a2a411`）来搞 2.5G 口，方向是错的。
实机全总线扫描 + 32 个寄存器 dump + 写回测试给出的结论：

```
dump 07: 00=1040 01=7949 02=4f51 03=ea19 04=11e1 06=0064 07=2001
wtest 07: bmcr 1040 -> 5040 loopback=STUCK      <- 写得进去，真芯片
```

`0x4f51ea19` 正是主线 `drivers/net/phy/motorcomm.c` 里的
`PHY_ID_YT8821`。而 `0x0f` 上根本没有芯片（原厂 U-Boot 也报过
`Could not get PHY ... addr 15`），EN8811H 灌固件那 7.5 秒超时纯属白等：

```
en8811h_wait_mcu_ready failed: -110      (ETIMEDOUT)
Load firmware failed: -19                (ENODEV)
lan1: validation of 2500base-x ... failed: -EINVAL
```

现在的 dts 写法：

```dts
&mdio_0 {
    yt8821: ethernet-phy@7 {
        compatible = "ethernet-phy-ieee802.3-c22";
        reg = <0x7>;
    };
};
...
&gdm3 {
    phy-handle = <&yt8821>;
    phy-mode = "2500base-x";
};
```

用 `ethernet-phy-ieee802.3-c22` 让内核自己读硬件 ID，读回 `0x4f51ea19`
就会绑 motorcomm 驱动。这颗 PHY 上电即可应答，不需要复位脚。

**已知隐患**：`target/linux/generic/hack-6.18/755-*.patch` 是主线社区给
Cudy M3000 写的 YT8821「MDIO 总线地址 0 冲突」临时方案 —— Motorcomm
错误地把地址 0 当广播地址，会响应本来发给别的 PHY 的命令，导致寄存器
被破坏（千兆链路报成 100Mbps）。该补丁靠 `reset-gpios` 复位 PHY，
而本板 `yt8821` 节点没有 `reset-gpios`，所以复位那一步走空路径，
只有「关掉地址 0 广播」生效。够不够要看长时间稳定性。


---

## 八、阶段七：吞吐实测与调优

线路签约：下行 1000 / 上行 50，湛江电信。ISP 官方测速：592.76 Mbps。

### 8.1 局域网（lan1 / 2.5G 链路，iperf3 -P4）

| 配置 | 下行 | 上行 |
|---|---|---|
| RPS 关闭 | 2.09 Gbps | 1.62 Gbps |
| RPS 打开（`rps_cpus=3`） | 2.08 Gbps | 1.62 Gbps |

**结论：RPS/RFS 无收益**，收包路径本来就在两核之间分配好了。
`/etc/init.d/tune` 只保留 `netdev_max_backlog=1000`。

CPU 未降频：CoreMark 4079.97（与禁用 cpufreq 前的 4080.5 一致）。

### 8.2 广域网（PC 经 ONU）

| 方式 | 结果 |
|---|---|
| 单连接（南大/清华镜像） | 19–20 Mbps（**同源走 Wi-Fi 也是这个数 → 源限速，不是 ONU**） |
| 16 并发 | 432 Mbps |
| 32 并发（PowerShell 作业，10 s 窗口） | 575 Mbps |
| 32 并发（接口计数，20 s 稳态） | **456.6 Mbps** |
| 负载时 CPU | 63–72%（双核），load 0.45–0.78 |

**结论：ONU 下行可跑 456–575 Mbps，达到 ISP 官方 593 Mbps 的 77–97%；
瓶颈在测试源（学术镜像单连接限速），不在 ONU。**

---

## 九、阶段八：sysupgrade 支持

### 9.1 `platform_check_image` 的魔数 bug

原实现用 `get_magic_word`，其内部是 `dd bs=2 count=1`，**只读 2 个字节**，
在这台机器上只返回 `d00d`，与 `d00dfeed` 永不相等 → 任何镜像都判"不是 FIT"。

```sh
[ "$(hexdump -v -n 4 -e '1/1 "%02x"' "$1" 2>/dev/null)" = "d00dfeed" ] || {
	echo "镜像头部不是 FIT，拒绝刷写"
	return 1
}
```

### 9.2 元数据尾部不能手工拷贝

重建 sysupgrade.bin 时手工拷旧镜像的元数据尾部 → squashfs 大小一变，
元数据相对文件末尾的对齐就错了，fwtool 读不回来（`Image metadata not present`）。

正确做法：

```sh
echo '<json>' | fwtool -I - 镜像
```

对齐由 fwtool 自己算。验证：`sysupgrade -T /tmp/sysupgrade-new.bin` 通过。

---

## 十、阶段九：IPTV（组播）

### 10.1 决定性证据

PON 在线期间 `channel_0_rx_packets` 达到 **4,034,512** —— OLT 一直把组播流
推给 ONU，电视信号其实已经在进来了，只是没有送到机顶盒。

### 10.2 OLT 下发的业务

| 业务 | VLAN | GEM | 说明 |
|---|---|---|---|
| 上网 | 41 | 1035 | 已验证 |
| 未知 | 45 | 1034 | 很可能是 IPTV |
| 未知 | 46 | 1033 | |
| 组播 | 50 | 4095（alloc_id 0xffff） | IGMP/组播 |

### 10.3 提供的工具

```
pon-iptv on [vlan] [port]   # 默认 45 / lan4，建 br-iptv + IGMP snooping
pon-iptv off
pon-iptv status
```

内核侧：`br-lan` 有 `multicast_snooping`；`/proc/net/ip_mr_vif` 存在
（IP 组播路由已编入）；但 **igmpproxy / udpxy 未安装**（feeds 里有）。

已实测：建立/拆除都不影响 br-lan 与 SSH，lan4 会临时从 br-lan 移出。

---

## 十一、构建与刷机流程

### 11.1 构建

```bash
bash /mnt/h/Deepseek/WSL/build70.sh
```

`build70.sh` 做三件事：正常 `make` → 解包 squashfs 打补丁 → 重打包发布。

> 为什么不能在 base-files 里塞文件：`make target/install` 会从 base-files 的
> ipkg/rootfs 缓存重新组装 rootfs，把我们塞进去的文件覆盖掉。
> **所以 5380A 的自定义文件（`board/` 下）只能注入到 squashfs 重打包这一步。**

### 11.2 刷机（在 OpenWrt 里，不需要 U-Boot）

```sh
# 从 PC 推镜像
cat root.squashfs | ssh root@192.168.1.1 'cat > /tmp/root.squashfs'
ssh root@192.168.1.1 'mtd -r write /tmp/root.squashfs apps'
```

U-Boot 方式（内核或救援时）：

```
tftpboot 0x90000000 kernel.itb
mtd erase airoha-flash 0x3100000 0x600000
mtd write airoha-flash 0x90000000 0x3100000 0x5A5800
reset
```

> ⚠️ **`mtd write` 前必须 `mtd erase`**，否则未擦除页写入会 ECC 失败并标记坏块。
> ⚠️ 永远不要写 mtd0（0x0–0x280000）和 factory（0xE700000）。

### 11.3 通用坑

- **drvfs 丢执行位**：仓库在 H: 盘，git 检出文件权限是 644。改动的可执行文件
  必须 `chmod 755` + `touch` 强制重装。
- **ipkg/rootfs 缓存**：`make package/install` 之后它会覆盖注入的文件。

---

## 十二、最终成果

| 项目 | 状态 |
|---|---|
| 引导 | ✅ U-Boot 从 NAND 自启动（KernelB 的内核 FIT） |
| 根文件系统 | ✅ squashfs @ `apps`(mtd6) |
| 配置持久化 | ✅ ext4 @ `rootfs_data`(mtd7) |
| LAN1 2.5G | ✅ YT8821，实测 2.34 Gbps（4 流 iperf3 下行） |
| LAN2~4 | ✅ 交换芯片内部 PHY |
| MAC / PON SN | ✅ 来自 factory、identity 分区 |
| 光模块 | ✅ UX3363，BOSA 校准 `calibration ready` |
| **PON 注册** | ✅ **O5，onu_id 153，XG-PON，ZTEG OLT** |
| **OMCI** | ✅ **LOID 认证通过，T-CONT/GEM/VLAN 全部下发** |
| **PPPoE 上网** | ✅ **pon0.41，456–575 Mbps（ISP 官方 593）** |
| 复位键 | ✅ GPIO35，长按 5 秒 FACTORY RESET |
| 光信号灯 | ✅ GPIO33，trigger `pon0-los` |
| LuCI | ✅ `http://192.168.1.1`，含上游 `luci-app-pon` 完整 4 个页面 |
| sysupgrade | ✅ 已验证（`sysupgrade -T` 通过） |
| IPTV | ⏳ 工具就绪，待光纤可用时现场验证 |
| 光宽带灯 | ❌ PWM 通道 10，需 pinctrl 补丁（与 gpio18 冲突） |
| 网络灯 | ❌ 无 GPIO，推测 PHY LED 输出 |
| NPU | ❌ 闭源固件卡在 `NOTICE: Get secure key in flash`，已放弃 |
| cpufreq | ⚠️ 6.18 解析 OPP 表 panic，已从 DTS 摘除；空闲 77–79 °C |

### 内置工具

| 路径 | 作用 |
|---|---|
| `/usr/bin/pon-selftest` | PON 全状态自检（一行命令输出全部） |
| `/usr/bin/pon-mode` | 运行时切换 xgpon / gpon |
| `/usr/bin/autoprobe` | 开机自动判定 PON 模式 |
| `/usr/bin/pon-restart` | 重启 pon0 接口 |
| `/usr/bin/pon-iptv` | IPTV 桥接（on/off/status） |
| `/etc/init.d/tune` | 开机设 `netdev_max_backlog=1000` |

---

## 十三、遗留与下一步

1. **IPTV 现场验证**（需光纤空闲）：
   `pon-iptv on 45 lan4`，机顶盒插 lan4，看组播组与 `channel_0_rx_packets`。
   若拿不到地址/无图像：改试 46；仍不行则编入 igmpproxy 做代理。
2. **光宽带灯**：给 pinctrl 驱动打补丁，把 gpio18 从
   `pon_tx_disable_gpio_pins[]` 摘掉，再启用 pwmleds。
3. **散热**：空闲 77–79 °C 偏高，建议加散热片。
4. **Hardware identity 页面**：需要 identity 分区的字段描述才能启用。
5. **公网 IP**：当前拿到的是 100.64.2.104（CGNAT 段），后续可确认是否有公网地址。

---

## 附：关键代码位置

| 内容 | 路径 |
|---|---|
| 5380A 自定义文件 | `H:\Deepseek\ponwrt-fork\board\`（仅 5380A 构建时注入） |
| 设备树 | `target/linux/airoha/dts/an7583-fiberhome-hg5380a.dts` |
| 构建脚本 | `H:\Deepseek\WSL\build70.sh` |
| 源码仓库 | `H:\Deepseek\ponwrt-fork` |
| 构建树 | WSL `/home/build/openwrt` |
| 原厂备份 | `G:\刷机\路由器\TYFZA1\新建文件夹\5380A\mtd0.bin` ~ `mtd9.bin` |
| 可用镜像备份 | `G:\刷机\路由器\TYFZA1\新建文件夹\5380A\backup-2026-11-03\` |
