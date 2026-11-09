# HG5380A 功能测试清单

> 用于固件刷入后的逐项验证。每项都写明**怎么测**、**期望结果**、
> **失败时怎么看**。串口是主要观测通道（COM4, 115200 8N1，root 免密登录）。
>
> 最后更新：2026-11-10

---

## 一、刷机前

### 1.1 备份当前系统（可选但强烈建议）

```sh
# 在设备上
dd if=/dev/mtd2 of=/tmp/KernelA.bin     # 原厂内核
dd if=/dev/mtd3 of=/tmp/RootfsA.bin     # 原厂根
# 通过 scp 取回
```

分区布局见 `hg5380a-porting-log.md` 第一节表。**`mtd0`(bootloader) 绝对不碰。**

### 1.2 记录当前版本

```sh
cat /etc/openwrt_release
cat /tmp/sysinfo/board_name
uname -a
```

---

## 二、刷机

在 OpenWrt 系统内 sysupgrade，**不需要 U-Boot**：

```sh
# 上传固件
scp 5380A-sysupgrade.bin root@192.168.1.1:/tmp/

# 设备上
sysupgrade -v /tmp/5380A-sysupgrade.bin
```

`-v` 保留配置；首次从别的版本过来建议不带 `-v`（干净刷）。

**刷机全程不要拔插网线**——`br-lan` 会 down，`odhcpd` 会重置 RA。

---

## 三、启动与基础检查

| # | 检查项 | 命令 | 期望 |
|---|---|---|---|
| 3.1 | 能启动 | 串口看 | 出现 `root@ponwrt:~#` |
| 3.2 | 版本正确 | `cat /etc/openwrt_release` | `DISTRIB_REVISION` 与本次编译一致 |
| 3.3 | 板型识别 | `cat /tmp/sysinfo/board_name` | `fiberhome,hg5380a` |
| 3.4 | 内核版本 | `uname -a` | `6.18.60`（或本次实际内核） |
| 3.5 | 无 panic/oops | `dmesg \| grep -iE 'panic\|oops\|BUG:'` | 无输出 |
| 3.6 | 分区表 | `cat /proc/mtd` | 13 个 mtd，与文档表一致 |
| 3.7 | squashfs 挂载 | `mount \| grep rom` | `/dev/root on /rom type squashfs` |
| 3.8 | overlay 可用 | `df -h /` | overlayfs 有可用空间 |
| 3.9 | 内存 | `free -m` | 总约 512 MiB |

---

## 四、LuCI（本次重点验证）

> 上一版 `r0-e1921dc` 就是这里挂了：16 个 luci 包全在，但没有 uhttpd。

| # | 检查项 | 命令 | 期望 |
|---|---|---|---|
| 4.1 | uhttpd 是否存在 | `ls -l /usr/sbin/uhttpd /etc/init.d/uhttpd /etc/config/uhttpd` | **三个文件都在** |
| 4.2 | uhttpd 进程 | `ps \| grep -v grep \| grep uhttpd` | 有进程 |
| 4.3 | 80 端口监听 | `netstat -lntp \| grep :80` | `0.0.0.0:80 LISTEN` |
| 4.4 | ubus RPC 模块 | `opkg list-installed \| grep uhttpd-mod-ubus` | 已安装 |
| 4.5 | LuCI 包数量 | `apk list --installed \| grep -c luci` | ≥ 17（应比上版多 luci-light） |
| 4.6 | 首页可访问 | 浏览器开 `http://192.168.1.1/` | 出现登录页 |
| 4.7 | 登录成功 | 用户名 root，空密码 | 进入概览页 |
| 4.8 | 菜单完整 | 浏览左侧菜单 | 状态/系统/网络/服务 都在 |
| 4.9 | 无 403 | 从内网另一台机访问 | 不出现 403（`rfc1918_filter=0`） |
| 4.10 | 保存生效 | 改个无关设置并保存 | 提示成功，不报 ubus 错误 |

**失败时看**：
```sh
logread | tail -30
cat /etc/config/uhttpd
uci show uhttpd
ubus list | grep -i luci
```

---

## 五、2.5G 口（lan1）与 YT8821

> 这是本次适配的核心硬件变更：PHY 从 EN8811H 纠正为 Motorcomm YT8821。

| # | 检查项 | 命令 | 期望 |
|---|---|---|---|
| 5.1 | PHY 被识别 | `dmesg \| grep -iE 'yt8821\|motorcomm'` | 出现 YT8821 / Motorcomm |
| 5.2 | 无 EN8811H 报错 | `dmesg \| grep -i en8811h` | **不应出现** `wait_mcu_ready` / `Load firmware failed` |
| 5.3 | PHY ID 正确 | `cat /sys/bus/mdio_bus/devices/*/phy_id 2>/dev/null` | 其中有 `0x4f51ea19` |
| 5.4 | 驱动已绑定 | `ls -l /sys/bus/mdio_bus/drivers/` | 有 motorcomm 相关目录 |
| 5.5 | lan1 存在 | `ip -br a show lan1` | 存在 |
| 5.6 | 链路 up | 插 2.5G 对端后 `cat /sys/class/net/lan1/operstate` | `up` |
| 5.7 | 协商速率 | `cat /sys/class/net/lan1/speed` | `2500` |
| 5.8 | 全双工 | `cat /sys/class/net/lan1/duplex` | `full` |
| 5.9 | 无 2500base-x 校验错 | `dmesg \| grep '2500base-x'` | **不应出现** `validation ... failed: -EINVAL` |
| 5.10 | 实际吞吐 | PC 侧 `iperf3 -c <路由器IP> -P4 -t 30` | 明显高于 1G 口（见 8.1 节基线） |
| 5.11 | 长时间稳定 | 连续跑 30 分钟 iperf3 | 不掉链、不降速到 100M |

**5.11 特别重要**：`755-*-yt8821-bus-collision-workaround.patch` 依赖
`reset-gpios` 才能复位 PHY，而本板 `yt8821` 节点没有该属性，
所以只有「关掉地址 0 广播」生效。若出现**千兆链路报成 100Mbps** 或
速率忽高忽低，就是这个 MDIO 地址 0 冲突没压住。

**失败时看**：
```sh
dmesg | grep -iE 'mdio|phy|gdm3|2500'
ethtool lan1
ethtool -m lan1 2>/dev/null
cat /sys/class/net/lan1/carrier
```

---

## 六、交换与 LAN 口

| # | 检查项 | 命令 | 期望 |
|---|---|---|---|
| 6.1 | 网桥成立 | `ip -br a show br-lan` | `192.168.1.1/24` |
| 6.2 | 四个 LAN 口都在桥里 | `bridge link show` 或 `ip link show master br-lan` | lan1~lan4 |
| 6.3 | lan2~lan4 能通 | 逐个插网线，PC 能获取 IP | 能 ping 通 192.168.1.1 |
| 6.4 | DHCP 正常 | PC `ipconfig /renew` | 拿到 192.168.1.x |
| 6.5 | 网口灯 | 目视 | 亮（注意：有 `Failed to setup PHY LED pinctrl` 报错时可能不亮） |
| 6.6 | VLAN 可用 | `ip link add link lan2 name lan2.100 type vlan id 100` | 创建成功 |

**已知问题**：`dmesg` 里会有 3 条
`mdio_bus mt7530-0: Failed to setup PHY LED pinctrl`，
影响网口指示灯，不致命，本次未修。

---

## 七、PON 与上网

| # | 检查项 | 命令 | 期望 |
|---|---|---|---|
| 7.1 | pon0 出现 | `ip -br a show pon0` | 存在（插光纤后） |
| 7.2 | XPON 驱动加载 | `lsmod \| grep -iE 'xpon\|en7572\|paged_bosa'` | 有 `airoha_xpon`、`airoha_en7572`、`airoha_paged_bosa` |
| 7.3 | BOSA 驱动绑定 | `dmesg \| grep -i bosa` | 无 probe 失败 |
| 7.4 | PON 状态 | `cat /proc/pon/status` 或 `ponctl status` | 有 O5（Operational）状态 |
| 7.5 | 光功率 | `ponctl` 相关命令 | 有收发光读数 |
| 7.6 | PPPoE 拨号 | `ifstatus wan` | `up: true`，拿到公网 IP |
| 7.7 | VLAN 41 | `ip -d link show pon0.41` | 存在，id 41 |
| 7.8 | 默认路由 | `ip r \| grep default` | 有默认路由 |
| 7.9 | 外网连通 | `ping -c4 223.5.5.5` | 通 |
| 7.10 | DNS | `nslookup www.baidu.com` | 解析成功 |
| 7.11 | PC 经路由上网 | PC 浏览器开网页 | 正常 |

**7.4/7.5 依赖真实 OLT**。没有光纤或不在 OLT 白名单上，`pon0` 不起、
O5 状态拿不到，属正常，不算缺陷。

**失败时看**：
```sh
dmesg | grep -iE 'xpon|pon|bosa|omci'
logread | grep -iE 'pon|omci'
cat /etc/config/pon
```

---

## 八、吞吐与性能

线路签约 1000/50（湛江电信）。基线来自 `hg5380a-porting-log.md` 8.1/8.2 节。

| # | 检查项 | 命令 | 期望 |
|---|---|---|---|
| 8.1 | 局域网（2.5G） | PC→路由器 `iperf3 -P4 -t 30` | 见日志基线 |
| 8.2 | 局域网反向 | `iperf3 -R -P4` | 对称 |
| 8.3 | 广域网下行 | PC 经 ONU 跑测速 | 接近签约值 |
| 8.4 | CPU 占用 | 跑 iperf3 时 `top` | 软中断有 offload 时不应打满 |
| 8.5 | NPU offload | `dmesg \| grep -i npu` | 看是否启用（本板曾因 NPU probe 卡启动而关闭） |

---

## 九、IPTV / 组播

| # | 检查项 | 命令 | 期望 |
|---|---|---|---|
| 9.1 | igmpproxy 在跑 | `ps \| grep -v grep \| grep igmpproxy` | 有进程 |
| 9.2 | udpxy 在跑 | `ps \| grep -v grep \| grep udpxy` | 有进程 |
| 9.3 | udpxy 端口 | `netstat -lntp \| grep udpxy` | 监听（默认 4022） |
| 9.4 | 组播转单播 | 播放器开 `http://192.168.1.1:4022/udp/<组播地址>:<端口>` | 能播放 |
| 9.5 | LuCI 前端 | 服务菜单里有 udpxy | 有配置页 |

没有 IPTV 账号时，9.4 只能验证端口在监听，无法验证实际流。

---

## 十、其他功能（full 档位）

| # | 检查项 | 命令 | 期望 |
|---|---|---|---|
| 10.1 | OpenClash 页面 | 服务 → OpenClash | 页面能开 |
| 10.2 | OpenClash 启动 | 点启用 | 能启动（**注意**：clash 内核二进制不在固件里，首次需在线下载） |
| 10.3 | SQM | 服务 → SQM | 页面能开；注意本基座无 `CONFIG_NET_SCH_CAKE`，cake 可能不可选 |
| 10.4 | ttyd | 浏览器开 `http://192.168.1.1:7681` | 能开终端 |
| 10.5 | 文件管理 | 服务 → 文件传输 | 能浏览目录 |
| 10.6 | USB 存储 | 插 U 盘 `lsblk` | 能识别 |
| 10.7 | ksmbd | `ps \| grep smbd` | 有进程（若启用） |
| 10.8 | 重启后配置保留 | `reboot` 再看配置 | 保留 |

---

## 十一、回归：这次改动没有破坏的东西

| # | 检查项 | 期望 |
|---|---|---|
| 11.1 | TYFZA1/5585F 相关文件未被动 | `git log --oneline -5` 里没有改动它们的提交 |
| 11.2 | 设备名仍是 `fiberhome_hg5380a` | `grep fiberhome_hg5380a target/linux/airoha/image/an7583.mk` 有一处 |
| 11.3 | 四个 PON 前端包都支持 AN7583 | `grep -c TARGET_airoha_an7583 feeds/pon_drivers/airoha-pon-frontends/Makefile` = 3 |
| 11.4 | 没有重复注册 TARGET_DEVICES | `grep -c 'TARGET_DEVICES += fiberhome_hg5380a' .../an7583.mk` = 1 |

---

## 十二、结果记录模板

```
测试日期：
固件版本：
sha256：

[基础]  启动 __ 版本 __ 板型 __ 内核 __ 无panic __
[LuCI]  uhttpd __ 80端口 __ 登录 __ 菜单 __ 保存 __
[2.5G]  PHY识别 __ 速率 __ 全双工 __ 吞吐 __ 30min稳定 __
[交换]  四口 __ DHCP __ 网口灯 __
[PON]   pon0 __ O5 __ PPPoE __ 外网 __
[吞吐]  局域网 __ 广域网 __
[IPTV]  igmpproxy __ udpxy __ 转单播 __
[其他]  openclash __ tqm __ ttyd __ USB __
[回归]  无副作用 __

遗留问题：
```
