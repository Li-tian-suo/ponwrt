# 5380A 编译配置核对表

> 每次编译前后核对，确保关键包都在。514 个包的 full 档位。
>
> 最后更新：2026-11-10

---

## 一、设备选择

```
CONFIG_TARGET_DEVICE_airoha_an7583_DEVICE_fiberhome_hg5380a=y
CONFIG_TARGET_DEVICE_PACKAGES_airoha_an7583_DEVICE_fiberhome_hg5380a=""
```

注意有两行相似但意义不同：

```
# CONFIG_TARGET_airoha_an7583_DEVICE_fiberhome_hg5380a is not set   ← 旧的符号，正常
CONFIG_TARGET_DEVICE_airoha_an7583_DEVICE_fiberhome_hg5380a=y       ← 真正生效的
```

`DEVICE_PACKAGES` 为空是对的——设备专属包写在 `board/an7583.mk.snippet`
的 `DEVICE_PACKAGES` 里（`kmod-phy-airoha-en8811h kmod-airoha-paged-bosa
kmod-airoha-en7572 kmod-airoha-xpon airoha-ponctl airoha-pond`），
不需要在 `.config` 里重复。

---

## 二、PON 链路（缺一不可）

| 包 | 期望 | 作用 |
|---|---|---|
| `CONFIG_PACKAGE_kmod-airoha-paged-bosa=m` | `=m` | UX3363 光模块驱动（paged BOSA） |
| `CONFIG_PACKAGE_kmod-airoha-en7572=y` | `=y` | EN7572 前端（换装时用） |
| `CONFIG_PACKAGE_kmod-airoha-xpon=y` | `=y` | XPON 主驱动，创建 `pon0` |
| `CONFIG_PACKAGE_airoha-pond=y` | `=y` | OMCI 守护 |
| `CONFIG_PACKAGE_airoha-ponctl=y` | `=y` | PON 控制工具 |
| `CONFIG_PACKAGE_kmod-phy-airoha-en8811h=y` | `=y` | 2.5G PHY 备选驱动（本板实际用 YT8821） |

**缺失后果链**：

```
kmod-airoha-paged-bosa 缺
  → dts 里 BOSA 节点无人绑定
  → airoha_pon_frontend_get() 拿不到 provider
  → airoha-xpon probe 失败
  → pon0 根本不出现
  → 没有 PON，没有上网
```

**为什么 `paged-bosa` 是 `=m` 而不是 `=y`**：它是 kernel module，
OpenWrt 里 kmod 包既可以是内置（`=y`）也可以是模块（`=m`），
`=m` 表示打进 ipk 由 procd 按需加载，`=y` 表示编进内核。
两者都会进镜像，功能等价。

### 上游 feed 的坑

`feeds/pon_drivers/airoha-pon-frontends/Makefile` 里：

```
DEPENDS:=@TARGET_airoha_an7581 +kmod-airoha-pon-frontend      ← paged-bosa 原样
DEPENDS:=@(TARGET_airoha_an7581||TARGET_airoha_an7583) ...    ← 另外两个包
```

只有 `paged-bosa` 漏了 AN7583。由 `board/airoha-paged-bosa-an7583.patch`
在 `feeds update` 之后应用修正。构建脚本会校验：

```sh
n=$(grep -c 'TARGET_airoha_an7583' feeds/pon_drivers/airoha-pon-frontends/Makefile)
[ "$n" = "3" ] || exit 1
```

---

## 三、LuCI 与 Web 服务器

| 包 | 期望 | 说明 |
|---|---|---|
| `CONFIG_PACKAGE_luci=y` | `=y` | 集合包 |
| `CONFIG_PACKAGE_luci-light=y` | `=y` | **关键**：带 `+uhttpd +uhttpd-mod-ubus` |
| `CONFIG_PACKAGE_luci-base=y` | `=y` | 前端框架 |
| `CONFIG_PACKAGE_uhttpd=y` | `=y` | Web 服务器 |
| `CONFIG_PACKAGE_uhttpd-mod-ubus=y` | `=y` | **关键**：LuCI 的 ubus RPC |
| `CONFIG_PACKAGE_luci-app-openclash=y` | `=y` | full 档位 |

**`luci-base` 的 `LUCI_DEPENDS` 里没有任何 Web 服务器**：

```
+rpcd +rpcd-mod-file +rpcd-mod-luci +rpcd-mod-ucode
+cgi-io +ucode +ucode-mod-fs +ucode-mod-log +ucode-mod-uci
+ucode-mod-ubus +ucode-mod-html +liblucihttp-ucode
```

真正携带 `+uhttpd +uhttpd-mod-ubus` 的是 `luci-light`：

```
LUCI_DEPENDS := +luci-app-firewall +luci-mod-admin-full +luci-proto-ppp \
                +luci-theme-bootstrap +rpcd-mod-rrdns \
                +uhttpd +uhttpd-mod-ubus
```

所以**不要只手写 `uhttpd=y`**——那样 `uhttpd-mod-ubus` 不会来，
LuCI 页面能开但所有功能报错（ubus RPC 不通）。

---

## 四、编译后必须核对 manifest

配置选中 ≠ 进了镜像。必须查 `*manifest`：

```sh
M=bin/targets/airoha/an7583/ponwrt-airoha-an7583.manifest
for p in uhttpd uhttpd-mod-ubus luci-base luci-light luci-app-openclash \
         kmod-airoha-paged-bosa kmod-airoha-xpon airoha-pond airoha-ponctl; do
    grep -qE "^${p} - " "$M" && echo "OK      $p" || echo "MISSING $p"
done
```

### 实测记录

**2026-11-10 5580A（314 包，minimal）** —— 全部通过：

```
OK      uhttpd                   uhttpd - 2026.08.24~373145f7-r2
OK      uhttpd-mod-ubus          uhttpd-mod-ubus - 2026.08.24~373145f7-r2
OK      luci-base                luci-base - 26.309.25350~319f7c9
OK      luci-light               luci-light - 26.309.25350~319f7c9
OK      kmod-airoha-paged-bosa   kmod-airoha-paged-bosa - 6.18.55-r12
OK      kmod-airoha-xpon         kmod-airoha-xpon - 6.18.55-r68
OK      airoha-pond              airoha-pond - 0.3.0-r2
OK      airoha-ponctl            airoha-ponctl - 0.2.0-r1
MISSING luci-app-openclash       （minimal 档位本来就没有，正常）
```

**2026-11-10 云端 Run #41（135 包，minimal，`5d4dce7`）**：

```
OK      uhttpd          uhttpd - 2026.10.19~ca796d7d-r1
OK      uhttpd-mod-ubus uhttpd-mod-ubus - 2026.10.19~ca796d7d-r1
OK      luci-light      luci-light - 26.309.25350~319f7c9
MISSING kmod-airoha-paged-bosa   ← 那份 workflow 是旧版，没有 Patch pon-drivers 步骤
```

这条记录说明：**LuCI 修复在云端和本地都生效**，
而 `paged-bosa` 缺失只是旧 workflow 的问题，当前代码已修
（`.github/workflows/build-hg5380a.yml` 第 136 行有 `Patch pon-drivers for AN7583`）。

---

## 五、假阳性：哪些 0 字节文件是正常的

排查编译污染时容易误判。以下 0 字节文件**本来就应该空**：

| 类型 | 例子 |
|---|---|
| OpenWrt stamp | `.built`、`.configured`、`.prepared`、`.xxx_installed`、`.dep_*` |
| musl 空头文件 | `toolchain-*/include/bits/*` |
| LLVM 测试夹具 | `rustc-*/src/llvm-project/*/test/Inputs/**/crtbegin.o` 等 |
| meson 符号占位 | `libzstd.so.*.symbols`、`libdbus-1.so.*.symbols` |

实测计数（2026-11-10 编译中）：

```
build_dir target 侧 0 字节目标文件   1411 个
  ├─ 1409 个在 host/rustc-*/src/llvm-project/*/test/    ← LLVM 测试夹具，正常
  └─    2 个在 zstd / dbus 的 .symbols                   ← meson 占位，正常
dl/ 下载缓存 0 字节文件              0 个                  ← 干净
```

**真正要担心的是 `staging_dir` 里 0 字节的 `.so`/`.a`/`.la`，
以及 `dl/` 里 0 字节的源码包**。

体检命令要按扩展名过滤，不能只看 `-size 0`：

```sh
# 正确
find staging_dir -type f \( -name '*.so*' -o -name '*.a' -o -name '*.la' \) -size 0

# 会误报
find staging_dir -type f -size 0
```

---

## 六、rust 是硬依赖

`airoha-ponctl` 无条件依赖 rust：

```
feeds/pon_userspace/airoha-ponctl/Makefile:11
PKG_BUILD_DEPENDS:=rust/host
```

所以 5380A 编译**绕不过 rust**。rust 从源码编译需要：
`dl/rustc/` 里的 1.95 引导链（3 个包）+ 107 MB 的预编译 LLVM
（`rust-dev-1.96.0-x86_64-unknown-linux-gnu.tar.xz`），
编译产物约 11 GB，耗时 40–90 分钟。

如果 `dl/rustc/` 里的包是 0 字节，rust bootstrap 会报：

```
thread 'main' panicked at src/bootstrap/src/core/download.rs:935:26:
member failed with premature eof
```

删掉坏文件让它重新下载即可。
