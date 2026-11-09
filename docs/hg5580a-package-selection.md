# HG5580A 软件包选型：体积与依赖陷阱

> 2026-11-08。记录这一轮踩到的体积和依赖问题，以及最后的选型。

## 一、问题起点

加完 homebox / iperf3 / IPTV 组播 / openclash 之后，rootfs 从
7.0 MB 涨到 36.3 MB。RootfsX 只有 `0x2800000` = 40 MiB，
余量只剩 5.4 MB，太挤。

实测各包体积（aarch64 apk，压缩后）：

| 包 | 体积 | 备注 |
| --- | --- | --- |
| luci-app-openclash | 7.95 MB | 单个包占 rootfs 22% |
| homebox | 3.80 MB | 压缩后的 14 MB 二进制 |
| python3-light | 2.99 MB | |
| libopenssl3 | 2.26 MB | 基础库 |
| libruby4.0 | 1.44 MB | 只因 openclash |
| libpython3 | 1.42 MB | |
| btrfs-progs | 1.08 MB | |
| wpad-openssl | 0.91 MB | |
| python3-codecs | 0.66 MB | |
| bash | 0.47 MB | 只因 openclash |

## 二、openclash 的真实代价

它的依赖声明：

```makefile
DEPENDS:=+luci-compat +dnsmasq-full +bash +curl +ca-bundle +ip-full +ruby \
         +ruby-yaml +kmod-inet-diag +kmod-nft-tproxy +kmod-tun +unzip
```

连带进来大约 10 MB：ruby 全家、bash、curl、unzip、
luci-lua-runtime、luci-lib-ipkg、luci-compat，还要把 dnsmasq 换成
dnsmasq-full。

## 三、平替评估

| 方案 | 依赖 | 体积 | 结论 |
| --- | --- | --- | --- |
| openclash | 12 项，含 ruby/bash | ~10 MB | 过重 |
| **homeproxy** | `+sing-box +firewall4 +kmod-nft-tproxy +ucode-mod-digest` | ~8 MB | **选用** |
| passwall | 依赖较多，需 lua 运行时 | 中等 | 备选 |
| xray-core | 无官方 LuCI | ~12 MB | 不选 |

homeproxy 功能覆盖 ss / vmess / trojan / hysteria / tuic，
自带 china_ip4、china_list、gfw_list 分流数据，
不需要替换 dnsmasq，也不需要 lua。

## 四、踩到的坑：sing-box 会拖入 libcronet

### 症状

全量编译卡在 `libcronet/compile` 半小时不动，
`ps` 里没有任何 gcc/go 子进程，只有 make 在等。

### 根因

`feeds/packages/net/sing-box/Makefile`：

```makefile
config SING_BOX_BUILD_NAIVE_OUTBOUND
def_bool y                                    # ← 每次 defconfig 都恢复成 y
depends on !(arc||armeb||loongarch64||mips||mips64||powerpc||TARGET_gemini)
```

而 `libcronet` 的下载地址是：

```
https://commondatastorage.googleapis.com/chromium-browser-clang/Linux_x64
https://storage.googleapis.com/chromium-optimization-profiles/pgo_profiles
```

要拉几百 MB 的 Chromium clang 工具链和 PGO 配置，国内网络必然卡死。

**手动把 `.config` 里的 `CONFIG_SING_BOX_BUILD_NAIVE_OUTBOUND` 改成 off
没有用** —— `def_bool y` 会在下次 `make defconfig` 时把它重新打开。

### 解法：改用 sing-box-tiny 变体

tiny 变体的同一个选项没有 `def_bool`：

```makefile
config SING_BOX_TINY_BUILD_NAIVE_OUTBOUND
bool "Build with NaiveProxy outbound support"
depends on !(...)
```

默认关闭。而 `Package/sing-box-tiny` 带 `PROVIDES:=sing-box`，
能满足 homeproxy 的 `+sing-box` 依赖。

tiny 变体默认开启的功能已经够用：

```
CONFIG_SING_BOX_TINY_BUILD_CLASH_API=y     homeproxy 需要
CONFIG_SING_BOX_TINY_BUILD_QUIC=y          hysteria / tuic
CONFIG_SING_BOX_TINY_BUILD_UTLS=y          TLS 指纹伪装
CONFIG_SING_BOX_TINY_BUILD_WIREGUARD=y
CONFIG_SING_BOX_TINY_BUILD_GVISOR=y
```

所以配置改成：

```
# CONFIG_PACKAGE_sing-box is not set
CONFIG_PACKAGE_sing-box-tiny=y
```

`libcronet` 从此完全不参与构建。

## 五、iperf 与 iperf3 的命名陷阱

本仓库里有两个目录：

```
feeds/packages/net/iperf    -> iperf 2.2.1，生成包 iperf
feeds/packages/net/iperf3   -> PKG_NAME:=iperf，版本 3.22，
                               但 BuildPackage 用的是 iperf3 / iperf3-ssl
```

两个包源码目录的 `PKG_NAME` 都叫 `iperf`，但生成的包名不同。
所以 `CONFIG_PACKAGE_iperf=y` 只拿到 iperf2，
要 iperf3 必须同时写 `CONFIG_PACKAGE_iperf3=y`。

## 六、最终包清单

保留：

```
homebox            内网测速（浏览器 + 自带 LuCI 页）
iperf              iperf2
iperf3 / iperf3-ssl iperf3
igmpproxy          IGMP 组播代理
udpxy              组播转 HTTP
luci-app-udpxy     对应界面
luci-app-homeproxy 透明代理
sing-box-tiny      代理核心
```

去掉：

```
luci-app-openclash   ruby   ruby-yaml   bash   unzip
luci-lua-runtime     luci-lib-ipkg      luci-compat
libcronet
```
