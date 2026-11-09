# HG5380A / HG5580A 板级成果合并进 ponwrt master

> 最后更新：2026-11-10
> 涉及提交：`aeaf6487`（合并）、`5d4dce7`（LuCI 修复）、`e1921dc`（libffi）

---

## 一、为什么不是 git merge

5380A/5580A 的板级工作原先在一个独立仓库里做：

| | `Li-tian-suo/ponwrt` (A) | `Li-tian-suo/ponwrt-hg5380a` (B) |
|---|---|---|
| 历史 | 完整 OpenWrt 历史，已同步上游 821 个提交 | 44 个压缩提交，根提交 `67ef80b` |
| 体积 | 440 MB | 97.9 MB |
| 上游关系 | 有 `upstream` = pbs05/ponwrt | 无 upstream |
| 内核补丁 | 174 个 | 172 个 |
| 5380A 状态 | 早期版（dts 8.2 KB） | **最终版**（dts 16.9 KB） |
| 5580A 支持 | 无 | 有 |
| `libffi` 包 | **自带**（3.8.0 + 22 patches） | 靠 workflow 运行时联网取 |
| TYFZA1/5585F | 有 | 无 |

两边根提交不同、没有任何共同祖先，`git merge` 与 GitHub 的 `merge-upstream`
都做不了（后者返回 HTTP 409）。所以采用**文件级精确搬迁**：把 B 的
5380A/5580A 成果搬到 A，A 保留上游同步、`libffi`、TYFZA1。

---

## 二、搬迁清单（17 个文件）

### board/（源，CI 运行时才 cp/cat 进源码树）

| 文件 | 变化 | 说明 |
|---|---|---|
| `an7583-fiberhome-hg5380a.dts` | 8248 → 16948 B | 含 YT8821 修正（见 4.1） |
| `an7583.mk.snippet` | 1165 → 1741 B | 设备定义，`DEVICE_PACKAGES` 含 `kmod-airoha-paged-bosa` |
| `an7583-fiberhome-hg5580a.dts` | 新增 | 5580A 设备树 |
| `hg5580a.mk.snippet` | 新增 | 5580A 设备定义 |
| `airoha-paged-bosa-an7583.patch` | 新增 | 让 `kmod-airoha-paged-bosa` 对 AN7583 可见（UX3363 光模块） |
| `04_pon_data_hg5380a` | 新增 | 仅存档，**故意不安装**（见 4.3） |
| `04_pon_data_hg5580a` | 新增 | 同上 |
| `hg5580a-vendor-header.bin` | 新增 | 厂商内核头，裸 FIT 用 |

### configs/

| 文件 | 变化 | 说明 |
|---|---|---|
| `hg5380a-packages.config` | 新增 | 5380A full 档位包清单（167 行） |
| `hg5580a-packages.config` | 新增 | 5580A full 档位包清单 |
| `an7583.config` | **定向改 5 行** | 见下 |

`an7583.config` 两边只差 14 行，其中实质差异就是 B 开了 5 个 busybox i2c 工具：

```
CONFIG_BUSYBOX_CONFIG_I2CGET=y
CONFIG_BUSYBOX_CONFIG_I2CSET=y
CONFIG_BUSYBOX_CONFIG_I2CDUMP=y
CONFIG_BUSYBOX_CONFIG_I2CDETECT=y
CONFIG_BUSYBOX_CONFIG_I2CTRANSFER=y
```

A 的这份文件已随上游同步（8827 行 vs B 的 8831 行，多 5 行上游新增配置），
**整文件覆盖会丢掉上游那 821 个提交带来的更新**，所以只做定向修改。

### .github/workflows/

| 文件 | 变化 |
|---|---|
| `build-hg5380a.yml` | 8875 → 15564 B |
| `build-hg5580a.yml` | 新增（19241 B） |

### target/linux/airoha/

| 文件 | 说明 |
|---|---|
| `dts/an7583-fiberhome-hg5580a.dts` | 5580A dts 的镜像副本 |
| `an7583/base-files/etc/uci-defaults/99_hg5580a_board_defaults` | 5580A 板级默认 |
| `an7583/base-files/lib/preinit/05_hg5580a_identity` | 5580A 身份（MAC/PON SN） |
| `an7583/base-files/lib/preinit/79_hg5580a_preinit_tmpfs` | 5580A 早期 tmpfs |
| `an7583/base-files/etc/init.d/hg5580a_overlay` | 5580A overlay 挂载 |

**注意 `board/` 下的 dts 与 `mk.snippet` 是「源」**：workflow 在构建时
才 `cp board/*.dts target/linux/airoha/dts/` 和
`cat board/*.mk.snippet >> target/linux/airoha/image/an7583.mk`
（`image/Makefile` 里 `DEVICE_DTS_DIR := ../dts`）。不要在 `target/` 下
直接改 dts 当源，下次构建会被覆盖。

### 文档

`docs/` 下 20 份 Markdown 全量迁移（约 142 KB），含
`hg5380a-porting-log.md`（502 行，13 个适配阶段）、
`hg5380a-vs-hg5580a-hardware.md`、`hg5580a-uboot-port-guide.md` 等。

---

## 三、合并后立刻暴露的三个缺陷

### 3.1 workflow 假设 `an7583.mk` 里已有旧设备定义

`build-hg5380a.yml` 原本要求必须删除一处 `Device/fiberhome_hg5380a` 块：

```python
new, n = pat.subn('', s, count=1)
if n != 1:
    sys.exit('ERROR: 未找到旧的 Device/fiberhome_hg5380a 定义...')
```

这是 B 的特征（B 的 `an7583.mk` 第 135 行确实写过一份），
而**同步上游后的 A 的 `an7583.mk` 是干净的上游版本，从来没有这个块**。
于是本地第一次编译立刻失败：

```
ERROR: 未找到旧的 Device/fiberhome_hg5380a 定义，请检查 an7583.mk 结构是否变化
```

改为「有则删、无则跳过」，两种仓库状态都能跑。

### 3.2 `Provide libffi` 会联网覆盖仓库自带版本

原步骤无条件 `git clone` openwrt 主树并 `cp -a` 覆盖 `package/libs/libffi`。
A 自带 libffi（3.8.0 + 22 patches），被覆盖后等于放弃已验证版本。
改为优先用自带，仅在缺失时回退联网。

实测日志确认生效：

```
OK: 使用仓库自带的 package/libs/libffi
make[3] -C package/libs/libffi host-compile
make[3] -C package/libs/libffi compile
```

### 3.3 `patch` 第二次运行会交互式卡死

`patch -p1 -d feeds/pon_drivers < board/airoha-paged-bosa-an7583.patch`
在补丁已应用过时会问：

```
Reversed (or previously applied) patch detected!  Assume -R? [n]
```

`make` 的 stdin 是 `/dev/null` 但 sh 里这条会永久阻塞。
加上 `--forward --batch` 使其幂等：

```sh
patch -p1 -d feeds/pon_drivers --forward --batch \
      < board/airoha-paged-bosa-an7583.patch
```

---

## 四、三个必须知道的设计约定

### 4.1 2.5G PHY 是 YT8821，不是 EN8811H

见 `hg5380a-porting-log.md` 第 7.6 节。要点：PHY ID `0x4f51ea19`、
MDIO 地址 `0x07`、`compatible = "ethernet-phy-ieee802.3-c22"`。
早期对 `0x0f` 灌 EN8811H 固件的那 7.5 秒超时是白等。

### 4.2 四个 PON 前端包必须都支持 AN7583

`feeds/pon_drivers/airoha-pon-frontends/Makefile` 里，上游只给
`kmod-airoha-paged-bosa` 写了 `@TARGET_airoha_an7581`，AN7583 下 Kconfig
里看不到这个包 → 选不中 → 不进镜像 → dts 里 BOSA 节点无人绑定 →
`airoha_pon_frontend_get()` 拿不到 provider → `airoha-xpon` probe 失败 →
**`pon0` 根本不出现**。

`board/airoha-paged-bosa-an7583.patch` 把它改成
`@(TARGET_airoha_an7581||TARGET_airoha_an7583)`。构建脚本会校验
`grep -c TARGET_airoha_an7583` 必须等于 3，否则报错退出。

### 4.3 `04_pon_data_hg5380a` 故意不安装

该文件给板级数据工具补 `pon_data` 目标（bosacal mtd11 / identity mtd12
各 128 KiB）。但上游 `03_pon_data` 里已有 `pon_data_target` 分支处理
「校准数据在 UBI 里」的情况，两份描述同时生效会让 `pon_data` 对象里
出现两套冲突的定位。`build-hg5580a.yml` 注释里写明了这一点，
5380A 同样不安装。

所以 `base-files/etc/board.d/` 下只有 `01_leds` 和 `02_network` 是正确的，
不是遗漏。

---

## 五、编译与刷机

### 5.1 云编译

GitHub Actions → `Build HG5380A (AN7583 FiberHome)` → Run workflow。
`profile` 输入可选 `minimal`（默认）或 `full`。

### 5.2 本地编译（WSL）

**必须用非 root 用户**，否则 autotools 拒绝：

```
configure: error: you should not run configure as root
         (set FORCE_UNSAFE_CONFIGURE=1 in environment to bypass this check)
```

`tools/tar` 就是卡在这里。正确做法：

```sh
chown -R build:build /home/build/hg5380a
su - build -c "cd /home/build/hg5380a && FORCE_UNSAFE_CONFIGURE=1 sh build.sh"
```

另外 `dl/` 可以软链到旧树的缓存省下载时间：

```sh
ln -s /home/build/openwrt/dl /home/build/hg5380a/dl
```

### 5.3 刷机

在 OpenWrt 系统内 sysupgrade，不需要 U-Boot：
见 `hg5380a-porting-log.md` 第 11.2 节。
`configs/an7583.config` 的 `CONFIG_TARGET_ROOTFS_SQUASHFS=y`，
产物是 `*squashfs-sysupgrade.bin`。

---

## 六、待验证

| 项 | 状态 |
|---|---|
| 合并后能否编译出固件 | 本地编译中（见 build log） |
| `uhttpd` / `uhttpd-mod-ubus` 是否进镜像 | 配置阶段已确认选中，等产物 manifest 复核 |
| 2.5G 口（lan1）能否协商 2500base-x | 需刷机后实测 |
| YT8821 地址 0 广播冲突的长期稳定性 | 需长时间跑 |
| mt7530 PHY LED pinctrl 报错（3 处） | 已知，影响网口灯，不致命，未修 |
