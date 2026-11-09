# HG5580A overlay 挂载失败的完整排查记录

> 2026-11-09。这一轮把 overlay 问题从"看起来能用"追到了真正的根因，
> 结论是 **JFFS2 在这块 NAND 上不可用，必须改用 UBIFS**。

## 一、症状

每次启动后：

```
root@(none):~#                      <- 主机名不是 ponwrt
mount | grep overlay   ->  空
/overlay               空目录
/etc/config/           只有 27 个默认文件，UCI 改动不持久
网络                    br-lan 没有 IP，LuCI 打不开
```

但手动 `PREINIT=1 mount_root start` **有时**能让 overlay 挂上，有时不行。

## 二、逐层排查

### 2.1 第一层：`/tmp` 不可写导致 mount_root 直接退出

`fstools/libfstools/mount_root.c` 的 `start()` 开头：

```c
data = volume_find(dataname);

if (!getenv("PREINIT") && stat("/tmp/.preinit", &s))
        return -1;                 // <- 静默退出，什么都不做
```

本机 bootargs 是 `root=/dev/mtdblock5 rootfstype=squashfs`，内核**直接把
squashfs 挂成 `/`**。于是 `/tmp` 是只读 squashfs 里的空目录，procd 的

```c
setenv("PREINIT", "1", 1);
fd = creat("/tmp/.preinit", 0600);      // 失败：只读文件系统
```

`creat` 失败，`/tmp/.preinit` 不存在，`mount_root` 看到
`!PREINIT && !/tmp/.preinit` 就 `return -1`，overlay 永远不挂。

**这一步修法**：preinit 早期挂 tmpfs 到 `/tmp` 并创建哨兵文件。

### 2.2 第二层：fstools 只认 `rootfs_data`，不认 `overlay`

`libfstools/mount_root.c`：

```c
char *dataname = "rootfs_data";
if (get_var_from_file("/proc/cmdline", "fstools_overlay_name", dataparam, sizeof(dataparam)))
        dataname = dataparam;
```

源码**支持** cmdline 覆盖，构建出来的二进制里也能看到
`fstools_overlay_name` 字符串，实测传 `fstools_overlay_name=overlay`
确实生效。

但即使生效，`volume_find("overlay")` 找到的是 **MTD 分区 mtd8**，而
mtd8 上没有任何可识别的文件系统时，`volume_identify()` 返回 `FS_NONE`，
于是：

```
mount_root: no usable overlay filesystem found, using tmpfs overlay
```

### 2.3 第三层：JFFS2 在这块 NAND 上根本无法格式化

把 mtd8 擦干净后尝试 JFFS2：

```
# mount -t jffs2 /dev/mtdblock8 /overlay
jffs2: cannot read OOB for EB at 017c0000, requested 8 bytes, read 8 bytes, error -74
mount: mounting /dev/mtdblock8 on /overlay failed: I/O error
```

`-74` 是 `EBADMSG`，**OOB 区 ECC 不可纠正**。

JFFS2 格式化时要在每个擦除块的 OOB 里写擦除计数器，读到坏的 OOB 就整块
失败。所以 JFFS2 在这块 flash 上**不可用**。

之前几次"成功"是假象：`df` 显示的是 `/tmp`（tmpfs），不是 mtd8。

### 2.4 第四层：overlayfs 嵌套深度

如果 `/` 已经是 overlay（上一次 ramoverlay 的残留），再叠加就报：

```
overlayfs: maximum fs stacking depth exceeded
mount_root: mount failed: Invalid argument
mount_root: switching to jffs2 failed - fallback to ramoverlay
```

## 三、真正的解法：UBI + UBIFS

UBI 对坏块有完整管理机制，实测这块 flash 在 UBI 眼里是**完全健康的**：

```
ubiformat /dev/mtd8 -y
  ubiformat: warning!: 1 of 192 eraseblocks contain non-UBI data
  ubiformat: formatting eraseblock 191 -- 100 % complete

ubiattach -m 8
  ubi1: attached mtd8 (name "overlay", size 24 MiB)
  ubi1: good PEBs: 192, bad PEBs: 0, corrupted PEBs: 0
  ubi1: available PEBs: 148 (17.9 MiB)

ubimkvol /dev/ubi1 -N overlay -m
  Volume ID 0, size 148 LEBs (18792448 bytes, 17.9 MiB), name "overlay"

mount -t ubifs ubi1:overlay /overlay
  UBIFS (ubi1:0): mounted UBI device 1, volume 0, name "overlay"
  DF: 14.7M total, 13.9M available
```

**关键：`bad PEBs: 0`。** 同一块 flash，JFFS2 说坏、UBI 说好——
差别在于 UBI 把坏块标记写到 OOB 的方式不同，且 UBI 有 40 个 PEB 的
坏块预留池。

### 3.1 fstools 原生支持 UBI 卷

`libfstools/ubi.c`：

```c
static struct volume *ubi_volume_find(char *name)
{
        ...
        while ((ubi_dirent = readdir(ubi_dir)) != NULL) {
                sscanf(ubi_dirent->d_name, "ubi%u", &ubi_num);
                ret = ubi_part_match(name, ubi_num);   // 按名字匹配
                if (ret)
                        break;
        }
}

static int ubi_volume_identify(struct volume *v)
{
        return FS_UBIFS;                // 总是 UBIFS
}
```

所以只要 **mtd8 已 attach 成 UBI 设备、且其中有一个名为 `overlay`
的卷**，fstools 就能自己找到并挂载 UBIFS，**不需要改 fstools**。

实测（先 `ubiattach`，再跑 mount_root）：

```
mount_root: switching to ubifs overlay
mount /overlay  ->  /dev/ubi1_0 on /overlay type ubifs (rw,noatime)
overlayfs:/overlay on / type overlay (rw,noatime,lowerdir=/,upperdir=/overlay/upper,...)
```

## 四、修复方案

新增 preinit hook
`target/linux/airoha/an7583/base-files/lib/preinit/79_hg5580a_preinit_tmpfs`，
在 `80_mount_root` 之前做三件事：

1. 挂 tmpfs 到 `/tmp`，创建 `/tmp/.preinit`，导出 `PREINIT=1`
2. 从 `/proc/mtd` 找到 `overlay` 分区的 MTD 序号
3. `ubiattach` 它（不是 UBI 就先 `ubiformat` + `ubimkvol -N overlay -m`）

然后让 mount_root 正常运行，它会自己发现 `ubiN:overlay` 并挂成 UBIFS。

### 4.1 分区表同时从 72 MiB 缩到 24 MiB

原来的 overlay 分区是 `0x4800000`（72 MiB），但坏块出现在
`0x4700000` 和 `0x47c0000` 附近。缩到 `0x1800000`（24 MiB）后
第一个坏块远在分区之外，且实测运行只用了 2.4 MB，24 MiB 完全够。

新的分区布局（算术已校验，无重叠）：

| 分区 | 偏移 | 大小 |
| --- | --- | --- |
| apps | 0x5f00000 | 32 MiB |
| **overlay** | 0x7f00000 | **24 MiB** |
| **apps_data** | 0x9700000 | 48 MiB |
| frameworka | 0xc700000 | 16 MiB |

## 五、排查中用到的验证手段

```sh
# 看 fstools 到底做了什么（ulog 输出到 syslog）
PREINIT=1 mount_root start 2>&1 | grep -iE "switch|usable|ubifs|jffs2"

# 看 cmdline 参数是否传进内核
grep -o "fstools_overlay_name=[a-z_]*" /proc/cmdline

# 看 preinit 有没有真的跑
dmesg | grep -E "init: - preinit -"

# 判断 mtd8 上有没有可用文件系统
mount -t jffs2 /dev/mtdblock8 /tmp/x && echo OK     # JFFS2 会失败
ubiformat /dev/mtd8 -y && ubiattach -m 8            # UBI 能成功

# 确认 UBI 卷
cat /sys/class/ubi/ubi1_0/name
```

## 六、遗留

- 新的 preinit hook 已编译进镜像（rootfs 28,133,234 B），但刷入后
  需要一次**真正的断电重启**才能验证，因为网络中断导致无法用
  `wget` 传输镜像。
- 验证要点：`dmesg | grep hg5580a-preinit` 应出现
  `overlay = ubiN:overlay (mtd8) ready`，且启动后主机名是 `ponwrt`。
