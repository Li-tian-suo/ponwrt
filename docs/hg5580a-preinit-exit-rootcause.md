# HG5580A overlay 挂载失败的真正根因（补充）

> 2026-11-11。之前那份 `hg5580a-overlay-postmortem.md`（11-09）把原因归到 JFFS2 和
> `/tmp` 不可写，方向对了一半，但不是根因。真正的根因是 **`/lib/preinit/*` 里写了 `exit`**。
> 这份文档是那一份的修正。

---

## 一、为什么之前的结论不完整

11-09 那次的证据是：

```
mount | grep overlay     -> 空
/overlay                 -> 空目录
/etc/config/             -> 只有 27 个默认文件
br-lan 没有 IP，LuCI 打不开
hostname (none)
```

然后手工执行 `PREINIT=1 mount_root start` **有时能挂上，有时不行**。

"有时能、有时不能"这个不稳定性把人引向了竞态、`/tmp` 挂载时序、JFFS2 坏块这些方向。
但真正的原因是：**手工执行时绕过了 `/etc/preinit`，所以在真实启动路径里那个 `exit`
根本没机会被执行到，也就没有机会中断 preinit。**

---

## 二、根因

`/etc/preinit` 是这样加载这些脚本的：

```sh
for pi_source_file in /lib/preinit/*; do
        . $pi_source_file
done
```

**`. ` 是 source，不是执行。** 所以脚本里的 `exit` 不会只退出自己，而是**终止整个
preinit 进程**，后面所有文件都不会被 source。

`05_hg5580a_identity` 里有 9 处 `exit`，最先命中的是这段：

```sh
CUR=$(dd if="$IDENTITY_DEV" bs=1 count=6 2>/dev/null | hexdump -v -e '1/1 "%02x"')
if [ -n "$CUR" ] && [ "$CUR" != "ffffffffffff" ]; then
	log "identity already holds base MAC $CUR, nothing to do"
	exit 0                     # <-- 这里
fi
```

设备上 identity 分区早已写好 MAC，所以**每次启动都走这条路径**。

### 证据一：`sh -x` 跟踪

```sh
PREINIT=1 sh -x /etc/preinit > /tmp/pd.log 2>&1
grep -oE "lib/preinit/[a-z0-9_]+" /tmp/pd.log | sort -u
```

结果：

```
lib/preinit/00_preinit
lib/preinit/02_default_set_state
lib/preinit/02_sysinfo
lib/preinit/04_set_netdev_label
lib/preinit/05_hg5580a_identity          <- 到此为止
```

后面 60 多个文件一个都没有被 source。其中三个是关键的：

```
79_hg5580a_overlay     挂 UBIFS overlay
80_mount_root          注册 do_mount_root
82_config_generate     生成 /etc/config/network 和 /etc/config/system
```

### 证据二：dmesg 时间戳

```
[    4.138135] init: - preinit -
[    4.440476] procd: - early -          <- 0.3 秒后就退了
```

正常的 preinit 要跑几秒。0.3 秒说明它在第五个文件上就结束了。

---

## 三、这一个 bug 解释了全部症状

| 症状 | 因果 |
| --- | --- |
| `/overlay` 空、根只读 | `79_hg5580a_overlay` 没跑，UBIFS overlay 没挂 |
| `/etc/config/network` 不存在 | `82_config_generate` 没跑 |
| `uci: Entry not found` | 同上 |
| `hostname (none)` | `/etc/config/system` 没生成 |
| `board.json` 悬空 | `/tmp/sysinfo` 没建（`/tmp` 还是只读的 squashfs） |
| `br-lan` 没 IP | `02_network` 的 uci 配置基于 `board.json`，而它不存在 |
| LuCI 打不开 | 没有 `network` 配置就没有 IP |
| 手工 `mount_root start` 有时能成 | 手工路径绕过了 `exit` |

**十几个看起来互不相干的症状，一个原因。**

---

## 四、修复

### 4.1 所有裸 `exit` 改成 `return`

```sh
# 改前
exit 0

# 改后
return 0
```

包在一个函数里，文件末尾调用：

```sh
hg5580a_identity_run() {
	...
	return 0
}

hg5580a_identity_run
```

`return` 只退出当前函数，不会终止 preinit。

**注意：awk 程序内部的 `exit` 不用改。** `get_conf()` 里有：

```sh
CONF=$(awk -v k="$2" '
	$0 ~ "^"k"=" { sub("^"k"=", ""); print; exit }
	END { }
' "$TABLE" 2>/dev/null)
```

这个 `exit` 只退出 awk，语义正确。

### 4.2 新增 `79_hg5580a_overlay`

排在 `80_mount_root` 之前，在文件被 source 时立即做三件事：

```sh
# a. devtmpfs：ubiattach 要 /dev/ubi_ctrl，/dev/kmsg 也要等它挂上才有
mount -t devtmpfs devtmpfs /dev 2>/dev/null

# b. tmpfs：让 .preinit 哨兵和 /tmp/sysinfo 有地方落
mount -t tmpfs tmpfs /tmp 2>/dev/null
chmod 1777 /tmp

# c. 哨兵 + PREINIT 环境变量，然后调 mount_root
: > /tmp/.preinit
PREINIT=1
export PREINIT
PREINIT=1 /sbin/mount_root start
```

为什么需要 b 和 c：`fstools` 的 `mount_root.c` 第 47 行

```c
if (!getenv("PREINIT") && stat("/tmp/.preinit", &s))
        return -1;
```

procd 在 `initd/preinit.c` 里虽然 `setenv("PREINIT","1",1)` 了，但 `/tmp` 此刻还是
只读的 squashfs，哨兵创建失败；而 `02_sysinfo` 的 `mkdir -p /tmp/sysinfo` 也失败，
连带 `board.json` 悬空、`02_network` 不执行。

---

## 五、修复后的验证

```sh
mount | grep overlay
```

```
/dev/ubi0_6 /overlay ubifs rw,noatime,assert=read-only,ubi=0,vol=6
overlayfs:/overlay / overlay rw,noatime,lowerdir=/,upperdir=/overlay/upper
```

```sh
uci get network.lan.ipaddr
hostname
```

```
192.168.1.1
ponwrt
```

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.1/
```

```
200
```

UBIFS 卷信息：

```
UBIFS (ubi0:6): mounted UBI device 0, volume 6, name "rootfs_data"
UBIFS (ubi0:6): FS size: 190717952 bytes (181 MiB, 1502 LEBs)
mount_root: switching to ubifs overlay
```

---

## 六、教训

**1. OpenWrt 的 `/lib/preinit/*` 是被 source 的，里面不能写 `exit`。**

这条对**所有** OpenWrt 目标都成立，不只是 Airoha。写这类脚本时用 `return`，或者把逻辑
包进函数里。

**2. "手工执行能成功"是一个强信号，说明问题在启动路径而不是在被调用的机制。**

如果 `mount_root start` 手工能跑通，那 `mount_root` 本身没问题，问题在"谁没调用它"。

**3. 一个只读的 `/tmp` 能引出十几个互不相干的症状。**

遇到"一堆东西都不对"，先找**最早的那个共同前提**，而不是逐个症状去修。
