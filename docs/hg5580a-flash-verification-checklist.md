# HG5580A 刷机验证清单

刷入 `G:\下载\5580A\sysupgrade-latest.itb`（md5 `39774e710371f992435e36c87a259adb`）
之后，按这个顺序验证。每一项都写了"期望值"和"不对时说明什么"。

一键脚本：`H:\Deepseek\hg5580a-port\verify-all-after-flash.sh`

---

## 0. 刷机前确认

```sh
# 包没坏
md5sum sysupgrade-latest.itb
# 39774e710371f992435e36c87a259adb

# U-Boot 网页恢复模式可达
ping 192.168.0.1
```

镜像内容已核对（`confirm-image-dtb.sh`）：

```
fdt-1  size 19138  crc32 2b9e662c  sha1 08395448795e...
构建产物  size 19138  crc32 2b9e662c  sha1 08395448795e...
三项全等 => 镜像内嵌的正是带 reset-gpios 的那个 DTB
```

---

## 1. 启动链

| 检查 | 命令 | 期望 |
| --- | --- | --- |
| 内核 | `uname -r` | `6.18.55` |
| 机型 | `cat /proc/device-tree/model` | `fiberhome,hg5580a-ubi` |
| 分区 | `cat /proc/mtd` | 6 个：`all_flash bl2 ubi factory bosacal identity` |
| 命令行 | `cat /proc/cmdline` | 含 `ubi.block=0,fit` |

**不对时说明什么：**

- 分区多于/少于 6 个 → 分区表被动过，立即停手
- 没有 `ubi.block=0,fit` → fitblk 没生效，rootfs 挂不上

---

## 2. overlay 与可写根

```sh
mount | grep -E 'overlay|ubi'
touch /etc/config/.rwtest && echo WRITABLE && rm -f /etc/config/.rwtest
df -h /overlay
```

期望：

```
/dev/ubi0_N /overlay ubifs rw,...
overlayfs:/overlay / overlay rw,lowerdir=/,upperdir=/overlay/upper
WRITABLE
```

**这一项是上一轮的核心修复。** 之前 `/lib/preinit/*` 是**被 source 的**，`05_hg5580a_identity` 里的 `exit 0` 终止了整个 preinit 进程，导致 `79_hg5580a_overlay`、`80_mount_root`、`82_config_generate` 全都没跑。

**不对时说明什么：**

- 只读根、`/etc/config` 写不了 → preinit 又被某个脚本的 `exit` 打断了。用
  `sh -x /etc/preinit` 跟踪，看停在哪个文件
- `/overlay` 没挂 → `mount_root` 找不到 `rootfs_data` 卷

---

## 3. 网络

```sh
uci get network.lan.ipaddr
ip -br link
hostname
ls -l /etc/board.json /tmp/sysinfo/board.json
```

期望：

```
192.168.1.1
lan2@eth0 UP / lan3@eth0 / lan4@eth0 / pon0 / br-lan UP
ponwrt
/etc/board.json -> /tmp/sysinfo/board.json  且文件存在
```

**不对时说明什么：**

- `uci: Entry not found` → `/etc/config/network` 没生成，`82_config_generate` 没跑
- `hostname (none)` → 同上
- `board.json` 悬空 → `/tmp` 还是只读，`79_hg5580a_overlay` 没生效

---

## 4. luci-app-pon

```sh
ls /usr/share/luci/menu.d/ | grep -i pon
ls /www/luci-static/resources/view/pon/
/usr/libexec/airoha-pon-data | head
```

期望：

```
luci-app-pon.json
config.js  diagnostics.js  hardware.js  status.js
（JSON 输出，含 ponctl 的数据）
```

浏览器打开 `http://192.168.1.1/`，左侧菜单应出现 **PON** 分组，含
状态 / 配置 / 诊断 / 硬件 四个页面。

**不对时说明什么：**

- 菜单没有 → `luci-app-pon` 没打进镜像（检查 squashfs 内容）
- 页面空白 → `airoha-pon-data` 执行失败，手动跑看报错

---

## 5. 2.5G 口（lan1 / gdm3 / YT8821）—— 本轮主要验证目标

### 5.1 复位线归属

```sh
grep -E 'gpio-28|gpio-15' /sys/kernel/debug/gpio
ls /sys/class/leds/
```

期望：

```
gpio-28 (                    |PHY reset       ) out hi
gpio-15 (                    |tx-disable      ) out hi
```

`/sys/class/leds/` 里**没有** `an8811_reset`，只有 `power` 和 `green:los`。

**这是本次修复的核心。** 之前 GPIO28 归 `gpio-leds` 的 `an8811_reset` 所有，PHY 驱动的 mdio 层拿不到 `reset_gpio`：

```c
void mdio_device_reset(struct mdio_device *mdiodev, int value)
{
	if (!mdiodev->reset_gpio && !mdiodev->reset_ctrl)
		return;                      /* ← 之前每次都在这里返回 */
	...
	if (mdiodev->reset_gpio)
		gpiod_set_value_cansleep(mdiodev->reset_gpio, value);
}
```

于是 `yt8821_config_init()` 开头那次"清掉 MDIO 总线冲突残留"的硬复位从未执行。

**不对时说明什么：**

- 消费者仍显示 `an8811_reset` → DTS 没生效，检查 dtb
- 显示 `PHY reset` 但没有 carrier → 复位修好了，问题在别处（见 5.3）

### 5.2 PHY 识别

```sh
P=/sys/bus/mdio_bus/devices/1fb00000.system-controller:mdio-bus@c8-mii:07
cat $P/phy_id
basename $(readlink $P/driver)
```

期望：

```
0x4f51ea19
YT8821 2.5Gbps PHY
```

这一项上一轮已经是对的，只作为回归检查。

### 5.3 链路状态

**插上 2.5G 电口网线到对端**，然后：

```sh
ethtool lan1 | grep -iE 'speed|duplex|autoneg|link detected'
cat /sys/class/net/lan1/carrier
cat /sys/class/net/lan1/operstate
```

期望（修复成功）：

```
Speed: 2500Mb/s
Duplex: Full
Link detected: yes
1
up
```

修复前是：

```
Speed: Unknown!
Duplex: Half
Link detected: no
```

### 5.4 通不通

```sh
udhcpc -i lan1          # 或者手工配同网段静态地址
ping -c4 <对端IP>
```

### 5.5 如果还是不通

已经排除的（不要再查）：

- PHY 识别与驱动绑定 ✓
- MDIO 总线可达 ✓
- `pcs-handle = <&eth_pcs>` 继承自 `an7583.dtsi`，`eth_pcs` status okay ✓
- `phy-mode` 必须是 `2500base-x`：`airoha_eth.c` 的 phylink 支持列表里没有 `PHY_INTERFACE_MODE_2500BASET`，写 `2500base-t` 会在 `phylink_validate()` 被拒，lan1 根本不会出现 ✓
- GPIO15 发送使能 ✓

剩下的方向：

1. `phy-mode` 改 `2500base-t` **不行**（MAC 不支持），但可以试 `sgmii` 或 `usxgmii` 看 phylink 是否接受
2. YT8821 的 `FORCE_BX2500` 模式（`yt8821_config_init` 在 `2500BASEX` 时会设）是否与对端速率匹配
3. 对端设备是否真的支持 2.5G 固定速率（很多 2.5G 网卡只走自协商）
4. 换 1G 端口/网线试，判断是不是只有 2.5G 有问题

---

## 6. PON

**必须接上光纤**，否则以下都是预期行为。

```sh
ponctl status
ls /sys/bus/i2c/drivers/airoha-paged-bosa/
dmesg | grep -iE 'bosa|calibration|optical'
```

### 没接光时的正常现象

```
optical signal present without XGTC sync; running short PMA recovery (recovery N)
XG-PON RX started, irq=29, ONU-ID=1023 (invalid), burst TX remains disabled
ONU 状态 O1，rx_power_dbm -40.0
```

原因链：

```
收不到下行 XGTC → RX_SYNC_ST ≠ RX_SYNC_IN
  → advance_xgtc() 走 recover_no_sync 分支
  → mac_initialized 永远 false
  → burst_profile_programmed 永远 false
  → try_arm_upstream() 第一组条件就 return
  → tx_enable(true) 从未调用
  → GPIO15 保持高（TX disabled）
  → ONU 停在 O1
```

### 接光后的期望

```
ONU 状态从 O1 → O2/O3 → O4 → O5
ONU-ID 从 1023 变成有效值
burst TX enabled
```

### 一个待确认的疑点

没接光时驱动却报 `optical signal present`。它的来源是：

```c
/* main.c:437 */
/* The active digital PCS supplies LOS when provider signal validity is absent. */
if (optical.signal_valid) {
	xpon->optical_signal = optical.signal_present;
} else {
	xpon->optical_signal = !airoha_xpon_xgpon_los(xpon);   /* 读 SFP_STA bit0 */
}
```

`bosa_frontend_ops` 没有 `.get_signal_status`，所以走的是后者。LOS 极性由光前端提供的
`xgpon_sfp_valid_level` 写到 `AIROHA_XGPON_PHY_SFP_VLD_LEVEL` 决定：

```c
/* regs.h 注释 */
/* SFP_VLD_LEVEL takes the complete IOT register value. EN7572 and compatible
 * 28L95 providers return 0x9 to set LOS/RX_RDY event polarity. */
```

**如果接光后 ONU 不注册，先怀疑这个极性值对 UX3363 不对。** 检查：

```sh
# 读回写入的值
devmem 0x1fa08b48 32
# 对比 UX3363 的 datasheet 期望值
```

---

## 7. 日志里该关注的

```sh
dmesg | grep -iE 'preinit|overlay|mount_root'
dmesg | grep -iE 'error|fail|warn' | grep -viE 'recovery|no XGTC'
```

**预期会有**（不影响功能）：

- `no XGTC sync` recovery 循环 —— 没接光就这样
- `Failed to setup PHY LED pinctrl` —— MT7530 内部 PHY 的 LED，之前就有
- `airoha-npu ... NOTICE: Get secure key in flash` —— NPU 已 disabled

**不该有**：

- `NAND initialization failed`
- `UBI: PEB size: 0 bytes`
- `No volume named fip`
- `uci: Entry not found`
- `mount_root: ... failed`

---

## 快速对照表

| 症状 | 第一嫌疑 | 查什么 |
| --- | --- | --- |
| 只读根 | preinit 被 `exit` 打断 | `sh -x /etc/preinit` |
| 无 `network` 配置 | `82_config_generate` 没跑 | 同上 |
| LuCI 打不开 | `/tmp` 只读，`board.json` 悬空 | `ls -l /etc/board.json` |
| 无 PON 菜单 | 包没打进去 | `ls /www/luci-static/resources/view/pon/` |
| lan1 无 carrier，gpio-28 还是 `an8811_reset` | DTS 没生效 | 检查 dtb |
| lan1 无 carrier，gpio-28 是 `PHY reset` | SerDes/对端速率 | 见 5.5 |
| ONU 停在 O1 | 没接光 / LOS 极性 | 见 6 |
| BL23 NAND 失败 | TF-A 表缺芯片 | 刷 preloader |
