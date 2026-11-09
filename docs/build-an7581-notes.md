# build-ponwrt-full.yml 本地复现记录

> 目标：按 `.github/workflows/build-ponwrt-full.yml` 在本地编译 **airoha/an7581**，
> 产出 `fiberhome_hg5585f-ct` 与 `nokia_xg-040g-md-ubi` 两块板子的固件。

## 一、工作流里写错/不存在的包（会导致 CI 失败）

| 工作流写的 | 真实情况 | 处理 |
|---|---|---|
| `CONFIG_PACKAGE_luci-app-advanced=y` | 该包不存在，正确的名字是 `luci-app-advanced-reboot` | 改名 |
| `CONFIG_PACKAGE_luci-app-argon-config=y` | 它是 `luci-theme-argon` 的 **PKG_PROVIDES** 虚拟包，不能单独选中（真正的配置界面由主题包提供） | 删除这一行 |
| `CONFIG_PACKAGE_luci-app-ddns-go=y` | 它 `LUCI_DEPENDS:=+ddns-go`，而 **feeds 里没有 `ddns-go` 这个包**，必然编译失败 | 移除；需要的话要把 ddns-go 的源加进 feeds |

另外工作流的 `Install Feeds` 只跑 `feeds install -a`，但 `Inject Packages` 却在
`feeds install` **之前**执行 —— 顺序反了。包符号在 `feeds install` 之前并不存在，
`make defconfig` 会把这些 `CONFIG_PACKAGE_xxx=y` 全部静默丢弃（表现为"配置里写了
但镜像里没有"）。**正确顺序：feeds update → feeds install -a → 改 .config → make defconfig**。

## 二、工作流缺失但必要的依赖

| 包 | 为什么必须 |
|---|---|
| `kmod-usb-storage` | 工作流只加了 `kmod-usb-storage-uas`，但没有基础的 `kmod-usb-storage`，UAS 驱动没有依赖链可依，U 盘挂不上 |
| `coreutils-nohup` | `luci-app-openclash` 运行依赖 |
| `luci-app-pon` | PON 管理页面；设备定义里只有 `kmod-airoha-xpon`/`airoha-pond`/`airoha-ponctl`，没有 UI |
| `libustream-openssl` | HTTPS（apk/curl/LuCI 下载）默认需要，显式列出避免被裁掉 |

## 三、本地复现要点

1. 工作流针对 `airoha/an7581`，与 HG5380A 的 `an7583` 是**不同子目标**，但同为
   `aarch64/cortex-a53`，**工具链可复用**（`staging_dir/toolchain-*`）。
2. `configs/an7581.config` 里已选中 4 个设备（hg5585f-ct、hg5585f-cu、
   xg-040g-md-ubi、zn515xg-d），`CONFIG_TARGET_PER_DEVICE_ROOTFS=y` —— 一次构建
   出多份固件。
3. 切换子目标会让内核与内核模块全部重编（用户态包也因目标 hash 变化而重编），
   首次约 40–90 分钟；之后增量很快。
4. 需要 Rust 才能编 `airoha-pond`：`./scripts/feeds install rust`，且 WSL 里要有
   `curl`（bootstrap 下载 stage0 用）。

## 四、本地实际使用的包清单

在工作流基础上：

- 删除：`luci-app-advanced`（改名）、`luci-app-argon-config`（虚拟包）、`luci-app-ddns-go`（缺依赖）
- 增加：`kmod-usb-storage`、`kmod-usb-storage-extras`、`coreutils-nohup`、
  `libustream-openssl`、`luci-app-pon`
- 改名：`luci-app-advanced` → `luci-app-advanced-reboot`
