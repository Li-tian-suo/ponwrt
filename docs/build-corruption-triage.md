# 编译中断后的污染排查手册

> 适用于 OpenWrt/PonWRT 编译进程被 SIGKILL（OOM、手动 kill、并行编译互相挤）
> 之后出现的一连串「莫名其妙的编译错误」。
>
> 最后更新：2026-11-10
> 相关：`hg5380a-merge-notes.md` 第 5.4 节

---

## 一、核心认识

**一次 SIGKILL 会污染整个源码树，而且污染表现千变万化。**

进程被杀时正在写的文件会变成 **0 字节**。这些 0 字节文件不会让 make 立刻报错，
而是等到**依赖它的那个包**编译时才炸，于是错误信息五花八门：

| 表面错误 | 真实原因 |
|---|---|
| `libtool: install: 'x.la' is not a valid libtool archive` | `.la` 是 0 字节 |
| `libtool: error: 'x.lo' is not a valid libtool object` | `.lo` 是 0 字节 |
| `No rule to make target 'install'` | 对应子目录是空的，configure 没跑完 |
| `make: *** No targets. Stop.` | build 目录只有 Makefile，源码没解压 |
| `Package requirements (x) were not met` | 依赖包的 `.pc` 文件缺失 |
| `undefined reference to xxx` | 汇编目标的 `.o` 是 0 字节，没进 `.a` |
| `Exec format error` | 可执行文件是 0 字节 |
| `configure: error:` （后面空白） | 依赖查不到，configure 提前死 |

**共同点**：报错的包看起来是「代码问题」，实际是**上一次编译的垃圾**。

本次实测：一次中断留下 **2619 个 0 字节目标文件** + 数个无源码的 build 目录
+ 缺失的 `.pc` 文件。逐个修了 8 轮才清干净。

---

## 二、第一步永远是体检

```sh
B=/home/build/hg5380a

# 1) target 侧 0 字节目标文件
find $B/build_dir/target-* -type f \
     \( -name '*.o' -o -name '*.lo' -o -name '*.a' -o -name '*.so*' -o -name '*.la' \) \
     -size 0 | wc -l

# 2) host / hostpkg 侧
find $B/build_dir/host $B/build_dir/hostpkg -type f \
     \( -name '*.o' -o -name '*.lo' -o -name '*.a' \) -size 0 | wc -l

# 3) staging 里 0 字节的库
find $B/staging_dir -type f \
     \( -name '*.so*' -o -name '*.a' -o -name '*.la' \) -size 0 | wc -l

# 4) 只有 Makefile 没有源码的 build 目录
for d in $B/build_dir/target-*/[a-z]*/; do
    [ -d "$d" ] || continue
    [ -e "$d/configure" ] || [ -e "$d/CMakeLists.txt" ] || \
    [ -e "$d/Makefile.in" ] || [ -e "$d/meson.build" ] || [ -d "$d/src" ] \
        || echo "无源码: $d"
done
```

**正常编译结束，这四项都应该是 0。**

注意：`staging_dir` 里的 `.xxx_installed`、`.built`、`.configured` 这类 **stamp 文件
本来就是 0 字节**，是正常的，别误删。要按扩展名（`*.so*` / `*.a` / `*.la` / `*.o` / `*.lo`）过滤。

同理 `include/bits/` 下的空头文件也是正常的。

---

## 三、清理策略：由轻到重

### 3.1 第一级：只删 0 字节文件（最安全）

```sh
find $B/build_dir/target-* -type f \
     \( -name '*.o' -o -name '*.lo' -o -name '*.a' -o -name '*.so*' -o -name '*.la' \) \
     -size 0 -delete
```

删完直接 `make -j12`。make 会重新编译这些目标。

**这一级解决大部分问题。** 本次 2619 个文件清掉后，失败包从 8 个降到 3 个。

### 3.2 第二级：删出问题的包的 build 目录

如果某个包报 `No targets. Stop.` 或 `No rule to make target`，
说明它的 build 目录不完整（源码没解压或 configure 没跑完）：

```sh
rm -rf $B/build_dir/target-*/acl-2.4.0
find $B/staging_dir/target-*/stamp -name '.acl*' -delete
find $B/staging_dir/target-*/pkginfo -name 'acl*' -delete
```

### 3.3 第三级：彻底清一个包的所有痕迹

有时只删 build 目录不够——`staging_dir` 里的 `pkginfo/*.install` 会让 make
误以为包已经装好了，于是 `compile` 只跑 0.1 秒就「成功」返回，但产物根本不存在。

**识别信号**：
```
time: package/libs/libnfnetlink/compile#0.12#0.09#0.21     ← 才 0.12 秒
```
正常编译不会这么快。

必须把这些全删：

```sh
P=libnfnetlink
rm -rf $B/build_dir/target-*/$P-*
rm -f  $B/build_dir/target-*/.$P* 
rm -f  $B/staging_dir/target-*/lib/lib$P* \
       $B/staging_dir/target-*/usr/lib/lib$P* \
       $B/staging_dir/target-*/usr/lib/pkgconfig/$P*.pc
rm -f  $B/staging_dir/target-*/stamp/.$P*
rm -f  $B/staging_dir/target-*/pkginfo/$P*
```

`/mnt/h/Deepseek/WSL/wipe_pkg.sh <包名>` 实现了这套逻辑。

### 3.4 第四级：整个 build 目录删除重来

万不得已：

```sh
rm -rf $B/build_dir $B/staging_dir $B/tmp
```

代价是全部重编（3~5 小时）。本次没用到这一级。

---

## 四、按错误类型对症下药

### 4.1 `libtool: 'x.lo' is not a valid libtool object`

```sh
find $B/build_dir -name '*.lo' -size 0 -delete
find $B/build_dir -name '*.o'  -size 0 -delete
```

如果删完还报，看该包的 build 目录里 `.libs/` 子目录，那里也有独立的 `.o`：

```sh
find $B/build_dir/hostpkg/libnl-3.12.0 -name '*.o' -size 0 -delete
```

### 4.2 `No rule to make target 'install'` / 子目录空

gcc 的 `libvtv/` 空目录就是典型。**这个不能靠删文件修**，
因为 make 需要该子目录的 Makefile，而 Makefile 由顶层 configure 生成。

必须删整个 build 子目录让它重新 configure：

```sh
rm -rf $B/build_dir/toolchain-*/gcc-14.4.0-final
rm -f  $B/staging_dir/toolchain-*/stamp/.gcc_final_*
su - build -c "cd $B && FORCE_UNSAFE_CONFIGURE=1 make toolchain/gcc/final/compile -j12"
```

### 4.3 `Package requirements (x) were not met`

依赖包的 `.pc` 不在。先确认：

```sh
ls $B/staging_dir/target-*/usr/lib/pkgconfig/x.pc
```

不在就重建那个依赖包（用 3.3 的彻底清法）。

本次是 `libnfnetlink.pc` 缺失导致 `libnetfilter-queue` 失败。
注意 `.pc` 装在 `usr/lib/pkgconfig/`，不在 `lib/pkgconfig/`。

### 4.4 `Exec format error`

可执行文件是 0 字节。定位：

```sh
find $B/build_dir -type f -name 'xxx' -size 0
```

本次是 rust 的 `libcxx-version`。

### 4.5 `member failed with premature eof`（下载缓存也中招）

```
thread 'main' panicked at src/bootstrap/src/core/download.rs:935:26:
member failed with premature eof
```

这是 **rust bootstrap 解压预编译 LLVM 包**时失败。根因：`dl/` 里的
`rust-dev-*.tar.xz` 是 **0 字节**。

**污染不只发生在 `build_dir`，`dl/` 下载缓存同样会被打断成 0 字节。**
这一点很容易漏查，因为大家通常只盯着编译产物。

必须单独体检 `dl/`：

```sh
# 找 0 字节或过小的包
find $B/dl -maxdepth 2 -type f \( -name '*.tar.*' -o -name '*.zip' \) -size -1k

# 校验 xz 包完整性
for f in $(find $B/dl -name '*.tar.xz'); do
    xz -t "$f" >/dev/null 2>&1 || echo "损坏: $f"
done

# gzip
for f in $(find $B/dl -name '*.tar.gz'); do
    gzip -t "$f" >/dev/null 2>&1 || echo "损坏: $f"
done

# zstd
for f in $(find $B/dl -name '*.tar.zst'); do
    zstd -t "$f" >/dev/null 2>&1 || echo "损坏: $f"
done
```

修复就是删掉坏文件让 make 重新下载：

```sh
find $B/dl -name 'rust-dev-*.tar.xz' -size 0 -delete
```

本次重下得到 107,444,652 字节的包，`xz -t` 校验通过。

---

## 五、rust 编译的两个专属坑

### 5.1 调用方式错了会得到假错误

```sh
# ❌ 错：TOPDIR 为空
make -C feeds/packages/lang/rust host-compile
# Makefile:25: /package.mk: No such file or directory
# make: *** No rule to make target '/package.mk'.  Stop.

# ✅ 对：走顶层目标
make package/feeds/packages/rust/host/compile
```

`-C` 直接进包目录时，`include $(INCLUDE_DIR)/package.mk` 里的
`INCLUDE_DIR` / `TOPDIR` 都是空的，于是路径变成 `/package.mk`。
**这个报错和 rust 本身毫无关系**，本次因此白折腾了几轮。

同理，`pkgerr.sh` 这类辅助脚本也要传顶层目标名
（`package/libs/openssl/compile`），不能传 `-C` 形式。

### 5.2 rust 为什么绕不过去

一度以为 rust 是被 ruby 的条件依赖误触发的，**判断错了**：

```
feeds/packages/lang/ruby/Makefile:32
PKG_BUILD_DEPENDS:=ruby/host RUBY_ENABLE_YJIT:rust/host RUBY_ENABLE_ZJIT:rust/host
                                    ↑ 这个是条件依赖，YJIT 带 "depends on BROKEN"，永远不成立
```

但真正把 rust 拉进来的是：

```
feeds/pon_userspace/airoha-ponctl/Makefile:11
PKG_BUILD_DEPENDS:=rust/host
                                    ↑ 无条件依赖
```

`airoha-ponctl` 是 5380A 的 `DEVICE_PACKAGES` 成员（PON 控制工具），
**rust 是硬需求，必须编出来**。

查「到底谁依赖了某个 host 包」的方法：

```sh
grep -rl 'rust/host' feeds/ package/ | while read -r f; do
    pkg=$(basename "$(dirname "$f")")
    grep -qE "^CONFIG_PACKAGE_${pkg}=y$" .config && echo "[选中] $pkg <- $f"
done
```

注意条件依赖 `COND:pkg` 的语义在 `include/version.mk` 里：

```make
define taint2sym
$(CONFIG_$(firstword $(subst :, ,$(subst +,,$(subst -,,$(1))))))
endef
```

即 `COND:pkg` 只有当 `CONFIG_COND` 为真时才生效。

---

## 六、避免再次发生

### 6.1 绝不同时跑两个 `make -jN`

```sh
nproc                 # 12
free -g               # 19 GB
```

一套 OpenWrt 全量编译用 `-j12` 就要 15~19 GB 峰值内存。
两套并行必然 OOM，被杀的留下满地垃圾，而且**报错完全不指向真正原因**。

要并行就降并行度：每套 `-j6`，并确认
`free -g` 的 available 至少 12 GB。

### 6.2 编译是否被中断的判据

* `make` 退出码不是 0 且**没有** `ERROR: xxx failed to build` → 被信号杀死
* `time: xxx/compile#0.1#...#0.2` 这种极短耗时 → stamp 欺骗，实际没编
* 日志尾部出现大段 `\0`（NULL 字节）→ 输出被截断，进程异常终止

### 6.3 日志必须用追加模式

```sh
make -j12 >> build.log 2>&1      # 不要用 >
```

用 `>` 每次重跑覆盖日志，第一次的真实错误就丢了。
本次排查中一度因为用 `>` 而抓不到错误，浪费了时间。

### 6.4 后台编译要用对脱离方式

在 WSL 里从 PowerShell 启动长期编译，这几种都**不可靠**：

| 方式 | 问题 |
|---|---|
| `Start-Process wsl ...` | WSL 会话结束即终止 |
| `nohup ... &` | 父 shell 退出时可能被回收 |
| `setsid nohup su - build -c ... &` | `su` 在无 tty 的新会话里会立刻退出 |

**可靠做法**：让 `pwsh` 工具自己 `run_in_background`，命令内部直接
`su - build -c "..."`，输出重定向到文件。工具管理进程生命周期。

### 6.5 定期体检

每次编译前后跑一次第二节的四项检查。0 字节文件数应该是 0。

---

## 七、本次实际修复记录

按时间顺序，共 8 轮：

| 轮 | 失败包 | 修法 |
|---|---|---|
| 1 | `tools/tar` | 改用非 root 用户编译（`FORCE_UNSAFE_CONFIGURE=1`） |
| 2 | `gcc/final`（`libstdc++.la`） | 删 0 字节 `.la`/`.so` + stamp |
| 3 | `gcc/final`（`libvtv` 空目录） | 删整个 `gcc-14.4.0-final` 重新 configure |
| 4 | `libunistring`/`libnl`/`ruby`/`rust`（host） | 清 hostpkg 0 字节 + 删 build 目录 |
| 5 | 8 个包（`acl`/`openssl`/`gmp`/`sqlite3` 等） | 清理 target 侧 **2619 个** 0 字节文件 |
| 6 | `acl`/`libnetfilter-cthelper` | build 目录无源码，删除重解压 |
| 7 | `libnetfilter-cttimeout`/`-queue` | 重建 `libnfnetlink`（`.pc` 缺失） |
| 8 | `tcpdump` | 重建 `libpcap`（无产物无 `.pc`） |
| 9 | `rust`（`Exec format error`） | 删 5.8 GB build 目录重编 |

---

## 八、可复用脚本

都在 `H:\Deepseek\WSL\`：

| 脚本 | 用途 |
|---|---|
| `clean_hostpkg.sh` | 清 host/hostpkg 侧 0 字节 + 删指定包 build 目录 |
| `clean_target.sh` | 清 target 侧 0 字节 + 删指定包 build 目录 |
| `wipe_pkg.sh <包名>` | 彻底清一个包的全部痕迹并重编 |
| `fix_gcc_final.sh` | gcc/final 专项修复 |
| `rebuild_gcc_final.sh` | gcc/final 删目录重编 |
| `pkgerr.sh <目标>` | 只打印某包编译的真实错误（过滤长 CFLAGS 行） |
| `diag_rust.sh` 系列 | rust 依赖链诊断 |

`pkgerr.sh` 特别有用——OpenWrt 的 `V=s` 输出里 CFLAGS 行长度上千字符，
会把真实错误挤出 `tail`。它过滤掉长行只留错误：

```sh
#!/bin/sh
cd /home/build/hg5380a || exit 1
su - build -c "cd /home/build/hg5380a && FORCE_UNSAFE_CONFIGURE=1 make $1 V=s" 2>&1 \
  | awk 'length($0) < 400' \
  | grep -iE 'error|No such file|cannot|undefined reference|Stop\.|fatal' \
  | head -25
```
