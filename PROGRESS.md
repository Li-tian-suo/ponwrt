# HG5380A (Airoha AN7583) 移植进度

> 最后更新：2026-11-02 15:35（按键与 LED 定型，内核 panic 已解决）

## 一、当前状态

| 项目 | 状态 |
|---|---|
| 引导 | ✅ U-Boot 从 NAND 自启动（KernelB 的内核 FIT） |
| 根文件系统 | ✅ squashfs @ `apps`(mtd6) |
| 配置持久化 | ✅ ext4 @ `rootfs_data`(mtd7) 上 bind `/etc/config`、`/etc/shadow`、`/etc/passwd`、`/etc/dropbear`、`/root`，并按镜像合并新增默认配置 |
| LAN1 2.5G | ✅ Motorcomm YT8821 @ MDIO 0x07，实测 **2.34 Gbps**（4 流 iperf3 下行） |
| LAN2~4 | ✅ 交换机内部 PHY（**本机无端口灯**） |
| MAC / PON SN | ✅ 来自 factory，`identity` 分区 |
| 光模块 | ✅ UX3363 @ i2c0 0x51，BOSA 校准 `calibration ready` |
| PON 注册 | ⏳ 需插光纤（当前 `optical signal absent`） |
| 复位键 | ✅ **GPIO35**（低有效），由 `gpio-button-hotplug` 接管 |
| 电源灯 | ✅ 硬件常亮（不受 GPIO 控制，DTS 不配） |
| 光信号灯 | ✅ **GPIO33**（低有效），trigger `pon0-los` |
| 光宽带灯 | ❌ 原厂为 PWM 通道 10（`pwm-leds "pon:green"`），本树无 PWM 控制器节点 |
| 网络灯 | ❌ 无 GPIO 能点亮，推测由交换芯片 PHY LED 输出驱动 |
| LuCI | ✅ `http://192.168.1.1` |
| NPU | ❌ 固件卡在 `NOTICE: Get secure key in flash`（闭源固件行为），已放弃 |
| cpufreq | ⚠️ 6.18 解析本 SoC 的 OPP 表会 panic，已从 DTS 摘除 OPP 引用，驱动按 ENOENT 放弃 |

## 二、最新镜像（build43，2026-11-02 15:31）

```
kernel.itb                      5920207  → KernelB @ 0x3100000（擦 0x600000，写 0x5A5800）
root.squashfs                   6653674  → apps    @ 0x5F00000（擦 0x660000，写 0x658800）
ponwrt-...-initramfs-uImage.itb 10470736 → TFTP 救援用（RAM 引导）
```

### 刷写（U-Boot）

```
tftpboot 0x90000000 kernel.itb
mtd erase airoha-flash 0x3100000 0x600000
mtd write airoha-flash 0x90000000 0x3100000 0x5A5800

tftpboot 0x90000000 root.squashfs
mtd erase airoha-flash 0x5F00000 0x660000
mtd write airoha-flash 0x90000000 0x5F00000 0x658800
reset
```

### 救援

```
tftpboot 0x90000000 ponwrt-airoha-an7583-fiberhome_hg5380a-initramfs-uImage.itb
bootm 0x90000000
```

## 三、分区布局（内核视角 13 个 mtd）

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

### U-Boot 环境

```
bootargs=console=ttyS0,115200 earlycon swiotlb=noforce root=/dev/mtdblock6 rootfstype=squashfs rootwait ubi.fm_autoconvert=1
bootcmd=mtd read airoha-flash 0x90000000 0x3100000 0x600000; bootm 0x90000000
bootdelay=3
```

## 四、关键发现（踩过的坑）

1. **2.5G PHY 是 Motorcomm YT8821**（MDIO 0x07，ID `0x4f51ea19`），不是 EN8811H。
   原厂 cmdline 的 `8811phy_addr` / `srdsEtherPhyTypeAllComp` 是 EVB 遗留和枚举名表。

2. **光模块是 UX3363**（i2c0 0x51，paged BOSA），不是 EN7572。
   校准表是 FiberHome BDBOB 格式（0x80 头 + 0x780 镜像），驱动已适配。

3. **复位键在 GPIO35**，不是原厂 DTB 写的 GPIO0。
   定位方法：把 0..38 全部挂成 `gpio-keys` 探针（label `k00`..`k38`），按一次键看
   `/proc/interrupts` 里哪个 label 的计数增长。注意 **gpio-keys 是整体设备，
   任一子节点取的引脚冲突会导致整个设备 probe 失败**，所以必须避开已被占用的引脚
   （PON 15~20、按键 35）。

4. **光信号灯在 GPIO33**（低有效）。电源灯硬件常亮；光宽带是 PWM(通道10)；
   网络灯无 GPIO 能点亮（推测 PHY LED 输出）。

5. **6.18 的 `dt_cpufreq` 解析本 SoC 的 OPP 表会 panic**：
   `_of_add_table_indexed → dev_pm_opp_of_cpumask_add_table → strcmp 野指针`。
   修法：DTS 里对 `cpu0/cpu1/cpufreq` 做 `/delete-property/ operating-points-v2`，
   并把 `cpufreq` 节点设为 disabled。注意 Kconfig 里 `ARM_AIROHA_SOC_CPUFREQ`
   会 `select CPUFREQ_DT`，**用 `# CONFIG_x is not set` 关不掉**，只能从 DTS 侧断。

6. **内核通用配置 `CONFIG_INPUT is not set`**，导致 `gpio-keys` 和
   `gpio-button-hotplug` 全是摆设。修法：`target/linux/airoha/config-6.18` 里开
   `CONFIG_INPUT=y`。同时必须把内核自带的 `KEYBOARD_GPIO` 关掉，否则会和
   `gpio-button-hotplug` 抢同名驱动（`Driver 'gpio-keys' is already registered`）。

7. **LuCI 403 的真凶是 `rfc1918_filter`**：内网设备访问自己管理界面时被判为
   DNS rebinding 而拒绝。镜像里已把默认值改为 0。
   另外老版 uhttpd 配置里的 `list lua_prefix .../sgi/uhttpd.lua` 也要删掉——
   我们用的是 ucode 版 LuCI，`/cgi-bin/luci` 直接按 CGI 执行。

8. **jffs2 在这颗 SPI-NAND 上不可能工作**（OOB 全被 ECC 占用），所以持久化只能
   用 ext4 分区 + bind 关键路径。**注意不能 bind 整个 `/etc`**，否则
   `/etc/init.d`、`/etc/rc.d` 被盖住，除 S05 外所有服务都不会启动。

9. **drvfs 丢执行位**：仓库在 H: 盘，git 检出文件权限是 644。已经坑过
   `/bin/board_detect`、`/etc/init.d/network`、`/sbin/ifdown`。改动的可执行文件
   必须 `chmod 755` + `touch` 强制重装。

10. **`mtd write` 前必须 `mtd erase`**，否则未擦除页写入会 ECC 失败并标记坏块。

11. **NPU 走不通**：驱动加载固件后，固件自己往 UART 打印
    `NOTICE: Get secure key in flash` 然后卡死。该字符串不在内核源码里，
    是闭源 RV32 固件的输出。LEDE 的 040G-MF DTS 也没有启用 NPU。

12. **驱动默认固件名是 `en7581_npu_*.bin`**，而镜像里是 `an7583_npu_*.bin`，
    必须用 `firmware-name` 属性显式指定（顺序：rv32、data）。

## 五、下次接着做

1. 刷 build43（上面四条命令），验证：
   - 按键：短按重启、长按 5 秒 failsafe；`logread` 里应出现 button 事件
   - 光信号灯：`echo 1 > /sys/class/leds/green:los/brightness` 能点亮
   - LuCI 正常
2. **PON**：插光纤后看
   `cat /sys/kernel/debug/airoha-xpon-pon0/{line,pcs,registration}`
3. 光宽带灯（PWM 通道 10）与网络灯（PHY LED）作为可选优化
4. 上行吞吐优化：NAPI RPS 把收包分散到两核（当前上行 1.72 Gbps，下行 2.34 Gbps）

## 六、文件位置

| 内容 | 路径 |
|---|---|
| 镜像（TFTP 根） | `G:\刷机\路由器\Tftpd64 v4.64\` |
| 源码仓库 | `H:\Deepseek\ponwrt-fork` |
| 构建树 | WSL `/home/build/openwrt` |
| 构建脚本 | `H:\Deepseek\WSL\build43.sh`（最新） |
| iperf3 客户端 | `H:\Deepseek\WSL\iperf3\iperf3.exe` |
| 原厂备份 | `G:\刷机\路由器\TYFZA1\新建文件夹\5380A\mtd0.bin` ~ `mtd9.bin` |

## 七、吞吐与调优实测（2026-11-02 16:00，lan1 / 2.5G 链路）

| 配置 | 下行 (iperf3 -P4) | 上行 (iperf3 -P4) |
|---|---|---|
| RPS 关闭 | 2.09 Gbps | 1.62 Gbps |
| RPS 打开（rps_cpus=3） | 2.08 Gbps | 1.62 Gbps |

结论：**RPS/RFS 无收益**，收包路径本来就在两核之间分配好了。`/etc/init.d/tune`
只保留 `netdev_max_backlog=1000`，不再动 rps_cpus。

CPU 未降频：CoreMark 4079.97（与禁用 cpufreq 之前的 4080.5 一致），
因此吞吐的小幅波动是测量噪声，不是频率问题。

## 八、内置脚本

| 路径 | 作用 |
|---|---|
| `/usr/bin/pon-selftest` | 一条命令输出全部 PON 状态（line/frontend/pcs/mac/registration/datapath + BOSA + LOS 灯 + 相关 dmesg） |
| `/etc/init.d/tune` | 开机设 `netdev_max_backlog=1000`（S99 自启） |

## 九、最新发布（build45，16:13）

```
root.squashfs  6654806 → apps @ 0x5F00000（擦 0x660000，写 0x659000）
ITB           10472852 → 救援用
```

build45 与 build43 的内核/DTS 完全相同，只是多了上面两个脚本，
所以只需要重刷 squashfs，不用动 KernelB。

## 十、2026-11-02 晚：按键 / LED / PON 页面 收尾

### 验证结果

| 项 | 结果 |
|---|---|
| PON 不再误报有光 | ✅ `dmesg` 只剩 `optical signal absent`，无 recovery 循环 |
| 光信号灯 | ✅ `green:los` 存在，无光时 `brightness=1`（亮） |
| 复位键 | ✅ 长按 5 秒触发 `FACTORY RESET`（procd 标准行为） |
| 恢复出厂后的持久化 | ✅ `/mnt/persist/etc/config/` 12 个文件完好，重启后 br-lan/192.168.1.1 自动恢复 |
| LuCI PON 页面 | ✅ 网络 → PON（自制页面，无需 Rust 的 airoha-ponctl） |

### 光宽带灯（PWM）的两个坑

1. **PWM 节点位置**：`pwm-airoha` 驱动用 `device_node_to_regmap(dev->parent)` 取寄存器，
   所以节点必须是 `system-controller@1fbf0200`（syscon）的子节点，**且不能有 `reg`**。
   写在顶层并带 reg → `probe failed with error -12`。
2. **gpio18 冲突**：`pinctrl-an7583.c` 的 `pon_tx_disable_gpio_pins[] = { 15, 16, 18, 19, 20 }`
   包含 gpio18，而本机"光宽带"灯正是 gpio18 的 PWM 通道 10。
   **绝对不能用删 `&xpon_mac { pinctrl-0 = <&pon_pins> }` 的办法绕过**——
   撤掉引脚复用后 PON 接收引脚浮空，会产生**假光信号**，驱动无限 recovery。
   正确做法是给 pinctrl 驱动打补丁把 18 从该组摘掉（等 PON 通了再做）。

### 按键行为

OpenWrt 标准：短按无动作，长按 5 秒 → FACTORY RESET。
`/etc/rc.button/reset` 是控制点，若要改成"短按重启"需修改该脚本。

### 已内置的脚本

| 路径 | 作用 |
|---|---|
| `/usr/bin/pon-selftest` | PON 全状态自检 |
| `/usr/bin/pon-restart` | 重启 pon0 接口 |
| `/etc/init.d/tune` | 开机设 netdev_max_backlog |
| `/www/luci-static/resources/view/pon/status.js` | LuCI PON 状态页 |
| `/usr/share/luci/menu.d/luci-app-pon-status.json` | 菜单项（网络 → PON） |
| `/usr/share/rpcd/acl.d/luci-app-pon-status.json` | ACL |

### 待办（都需要外部条件）

1. **PON 注册**：插光纤后先确认线路是 GPON 还是 X-GPON。
   可在 U-Boot 临时加 `xpon.mode=gpon`（不 saveenv）验证；若 GPON 能锁，
   就把 `airoha,default-line-mode = "gpon"` 写进 DTS。
2. **光宽带灯**：pinctrl 补丁（从 pon_tx_disable_gpio 组去掉 18）+ 启用 pwmleds。
3. **网络灯**：待 PON 通后用 `pon0-online` 触发器验证是否也是 PWM。
4. **USB3.0**（用户已焊接口）：控制器正常，待确认 VBUS 供电（可能需要 GPIO 使能）。

## 十一、2026-11-03 早上：PON 注册成功（O5）★★★

接入真实 OLT（光纤插到 PON 口），XG-PON 模式下一次通过：

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

### 当前卡点：OMCI 业务下发

```
rx_active: 1
upstream_tx_armed: 1
channel_0_rx_packets: 81     ← OMCI 报文已经收到 81 个
data_path_configured: 0      ← 没人处理
service_ready: 0
```

内核驱动把 OMCI 报文导出到 `omci0` / `oam0` 原始接口，正常由 Rust 写的
`airoha-pond`（feeds/pon_userspace/airoha-pon-daemons）处理，负责：
- 响应 OLT 的 MIB Upload / Create / Set / Get
- 建立 T-CONT / GEM port / VLAN 映射

没有它就不会有 `service_ready`，pon0 不会 carrier up，也就上不了网。

### 下一步（OMCI）两条路

1. **编译 Rust 版 airoha-pond**（推荐）
   - 需要 `rust/host` 工具链，构建机需能访问 crates.io / static.rust-lang.org
   - 本次尝试时 WSL 的 NAT 坏了（vEthernet 变 169.254），无法下载
   - 恢复办法：重启 Windows（会重建 WSL NAT）
2. **自己写最小 OMCI 响应器**（C）
   - 不依赖 Rust，但要实现 MIB（ONU-G / ONU2-G / ANI-G / T-CONT / GEM /
     MAC bridge / VLAN tag filter …），工作量大，且不同 OLT 行为差异多

### 已知问题（待下一版修）

1. `/etc/shadow`、`/etc/passwd` 用 bind 挂载导致 `passwd` 失败：
   ```
   passwd: can't create backup copy '/etc/shadow-': Cross-device link
   passwd: can't update password file /etc/shadow
   ```
   临时绕过：
   ```sh
   umount /etc/shadow /etc/passwd
   passwd
   cp /etc/shadow /mnt/persist/etc/shadow
   cp /etc/passwd /mnt/persist/etc/passwd
   ```
   新 persist 脚本已写好（board/persist：改成开机复制 + 每分钟回写），
   但受 base-files 的 ipkg/rootfs 缓存影响，没能进镜像。
2. `platform.sh`（sysupgrade 支持）同样因缓存问题未进镜像 → 刷机继续用
   `mtd -r write /tmp/root.squashfs apps`。
3. LuCI 密码一旦设置后，空密码登录失效；SSH 需要密码。

## 十二、2026-11-03 下午：全线打通，成功上网 ★★★★★

### 最终状态（实测）

```
PON:      configured_mode=xgpon  lifecycle=operational  onu_state=O5  onu_id=153
          optical_signal=1  xgtc_sync=in-sync  rx_power≈-14.6dBm
          收光正常，注册稳定（ploamd_accepted=9, rejected=0）

OMCI:     airoha-pond 运行中（PID 见 ps），loid_configured=true
          authentication_status=1 (accepted)，olt_vendor_id=ZTEG（中兴 OLT）
          rx/tx messages 269/269，parse_errors=0
          tcont_count=1  gem_port_count=4  vlan_rule_count=8
          vlan_ids=[41,45,46]  multicast=[50]
          backend_state=applied  active_alloc_id=1032  active_gem_id=1035

数据面:   data_path_configured=1  service_ready=1
          pon0 UP <LOWER_UP>，omci0 UP <LOWER_UP>
          内核日志 "data paths mapped: count=4"

PPPoE:    pon0.41（VLAN 41）
          local IP 100.64.2.104，对端 100.64.0.1
          DNS 202.96.134.133 / 202.96.128.166
          ping 223.5.5.5 = 16ms，HTTP 200

LAN→WAN:  电脑经路由器 ping 外网 16ms ✓
```

### 关键修复（今天逐个踩出来的）

1. **OMCI 守护进程**：必须编 `airoha-pond`（Rust）。构建过程中踩了：
   - `~/.wgetrc`、`~/.curlrc` 里的失效代理 → 清除
   - `rust` 包没 `feeds install` → 补装
   - WSL 里没有 `curl` → apt 装
   - rustc 源码包 231MB 下载慢 → 从 static.rust-lang.org 直连
   - 我们的 `pondctl` shim 与上游包冲突 → 删除 shim（包自带符号链接）

2. **`/etc/config/pon` 必须给 omci 段写 device**：
   ```
   config omci 'omci0'
       option line 'line0'
       option device 'omci0'
   ```
   缺了会报 "omci control device for line 'line0' is missing"，守护进程拒绝启动。

3. **防火墙的 wan 区域要包含 pppoe 接口**：
   ```
   uci add_list firewall.@zone[1].network='pppoe'
   ```
   否则 lan→pppoe 转发被 REJECT（表现为 ping 返回 `Destination port unreachable`，
   但路由器自身能上网——很容易误判为拨号失败）。

4. **PPPoE 必须用 pon0.41（VLAN 41）**，不能直接绑 pon0。OMCI 下发的分类规则
   按 VLAN 匹配 GEM，不带标签的帧全部 `tx_no_mapping` 丢弃。

### 构建流程（当前可用）

```bash
bash /mnt/h/Deepseek/WSL/build70.sh
```
它做三件事：正常 make → 解包 squashfs 打补丁 → 重打包发布。
（`make target/install` 会从 base-files 的 ipkg 缓存重新组装，覆盖我们塞进去的
文件，所以补丁必须放在 squashfs 重打包这一步。）

刷机（在 OpenWrt 里，不需要 U-Boot）：
```sh
# 从 PC 推镜像
cat root.squashfs | ssh root@192.168.1.1 'cat > /tmp/root.squashfs'
ssh root@192.168.1.1 'mtd -r write /tmp/root.squashfs apps'
```

### 遗留

- `sysupgrade` 仍不可用（platform.sh 缓存问题）→ 用 `mtd -r write`
- Hardware identity 页面未启用（需要 identity 分区的字段描述）
- 空闲温度 77-79°C（cpufreq 被禁用），建议加散热片
- UCI 里还有冗余的 `wan`/`wan6`（dhcp on pon0）接口，可清理

### 十三、有线测速结果（2026-11-03 傍晩）

线路签约（用户截图）：下行 1000 Mbps / 上行 50 Mbps，湛江电信
ISP 官方测速：592.76 Mbps，时延 22 ms，抖动 2 ms

本机实测（PC 经 ONU 上网，lan1 2.5G 链路）：

| 方式 | 结果 |
|---|---|
| 单连接（南大/清华镜像） | 19–20 Mbps（**同源走 Wi-Fi 也是这个数 → 源限速，不是 ONU**） |
| 16 并发 | 432 Mbps |
| 32 并发（PowerShell 作业，10 s 窗口） | 575 Mbps |
| 32 并发（接口计数，20 s 稳态） | **456.6 Mbps** |
| 负载时 CPU | 63–72%（双核），load 0.45–0.78 |

结论：ONU 下行可跑 456–575 Mbps，达到 ISP 官方 593 Mbps 的 77–97%；
瓶颈在测试源（学术镜像单连接限速），不在 ONU。若要再往上，可尝试 RPS 把
RX 软中断分到两个核（当前所有 airoha_eth 中断都落在 CPU0）。

注意：测速时不要把 PC 默认网关长期改到 192.168.1.1，测完要恢复 Wi-Fi 默认路由。

### 十四、IPTV 与 sysupgrade（2026-11-03 晚，光纤被家人看电视占用）

**sysupgrade 已修好并验证**
- `platform_check_image` 里原来用 `get_magic_word`，它内部是 `dd bs=2 count=1`
  只读 2 字节，返回 `d00d`，与 `d00dfeed` 永不相等 → 任何镜像都判"不是 FIT"。
  改成 `hexdump -v -n 4 -e '1/1 "%02x"'`。
- 重建 sysupgrade.bin 时**不能**手工拷旧镜像的元数据尾部：squashfs 大小一变，
  元数据相对文件末尾的对齐就错了，fwtool 读不回来（报 "Image metadata not present"）。
  正确做法：`echo '<json>' | fwtool -I - 镜像`，对齐由 fwtool 自己算。
- 验证结果：`sysupgrade -T /tmp/sysupgrade-new.bin` 通过。

**IPTV 现状与准备**
- OLT 下发的业务：单播 VLAN **41/45/46**（GEM 1035/1034/1033），组播 VLAN **50**
  （GEM 4095，alloc_id 0xffff）。41 已验证是上网，45 很可能是 IPTV。
- 决定性证据：PON 在线期间 `channel_0_rx_packets` 达到 **4,034,512** —— OLT 一直
  把组播流推给 ONU，电视信号其实已经在进来了，只是没有送到机顶盒。
- 内核支持：`br-lan` 有 `multicast_snooping` 开关；`/proc/net/ip_mr_vif` 存在
  （IP 组播路由已编入）；但 **igmpproxy / udpxy 未安装**（feeds 里有）。
- 已提供工具 `/usr/bin/pon-iptv`：
  ```
  pon-iptv on [vlan] [port]   # 默认 45 / lan4，建 br-iptv + IGMP snooping
  pon-iptv off
  pon-iptv status
  ```
  已实测：建立/拆除都不影响 br-lan 与 SSH，lan4 会临时从 br-lan 移出。

**待光纤可用时验证**
1. `pon-iptv on 45 lan4`，机顶盒插 lan4
2. `pon-iptv status` 看组播组是否出现、`channel_0_rx_packets` 是否增长
3. 若机顶盒拿不到地址/无图像：改用 46 试；仍不行则需编入 igmpproxy 做代理

**其它清理**
- 删除了冗余的 `wan`/`wan6`（dhcp on pon0）接口，wan 防火墙区域改为只含 `pppoe`。
  `uci-defaults-firewall` 已同步这一改动，重刷镜像后自动生效。
