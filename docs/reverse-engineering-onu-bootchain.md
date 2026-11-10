# 逆向一台闭源 ONU 的启动链

> 以 FiberHome HG5580A（Airoha AN7583）为例，记录从「只有串口和网线」到
> 「完整理解启动链并移植开源固件」的全过程。
>
> 本文不写结论清单，写**怎么得出结论**。所有判断都附证据来源。

---

## 0. 为什么启动链是第一优先级

拿到一台没有文档的 ONU，直觉是先看电路板、找调试口、猜密码。这些都不如
**先搞清楚它怎么启动**。原因：

启动链决定了后面所有事情的可能性边界。

```
ROM 从哪里读第一段代码？
  → 决定 bl2 分区能不能换、换多大

BL2 从哪里读后续镜像？
  → 决定分区布局能不能自定义

有没有签名验证？
  → 决定能不能跑自编译的固件
```

**这三个问题的答案，决定了这个移植项目是「一天」还是「不可能」。**

而它们的答案全都在**已有的二进制里**，不需要任何文档。

---

## 1. 第一步：拿到一份完整的 flash 备份

没有备份就没有退路。但在还没进去系统之前，怎么备份？

### 1.1 原厂 U-Boot 的 Web 界面通常有备份功能

FiberHome 这类 ONT 的 U-Boot Web 界面（通常是 `http://192.168.0.1/`）带有
分区备份下载。先枚举它接受什么参数：

```bash
# 列出可备份目标
curl -s http://192.168.0.1/api/storage | python3 -m json.tool
```

HG5580A 返回的目录里每个条目带 `kind`（`ubi` 或 `mtd`）、`target` 名字、
`size`。下载用斜杠分段格式：

```
GET /api/download/<id>/<offset>/<length>
```

单次上限 4 MiB，30 秒窗口。

### 1.2 备份的优先级

不是所有分区都同等重要。按「丢了能不能重建」排：

| 优先级 | 分区 | 为什么 |
| --- | --- | --- |
| 1 | `bootloader` | 含 BL2 + 签名 FIP，丢了要拆机用编程器 |
| 2 | `factory` | MAC、PON 序列号、光学校准，**不可再生** |
| 3 | `bosacal` / `identity` | 校准镜像（本机实测是空白，但别的批次可能有内容） |
| 4 | `apps` / `userdata` / `overlay` | 可放弃 |

**拿到备份之前不要写任何 flash。**

### 1.3 立刻验证备份的完整性

```bash
md5sum bootloader.bin factory.bin
# 记录到文档里，后面每次操作前对比
```

本机的值：

```
bootloader.bin   2,621,440 B   986fee15e5ad66ead92cadc7089ebb44
factory.bin      5,242,880 B   ab153adfd50625a7f83cf065894a37cc
```

---

## 2. 第二步：拆解 bootloader 镜像

`bootloader.bin` 是整个项目的钥匙。它的结构通常是：

```
偏移 0x0     第一级启动代码（ROM 跳到这里）
偏移 0x800   FIP 容器（Arm Firmware Image Package）
```

### 2.1 为什么是 `0x800`

这个偏移不是猜的，来自源码。Airoha 的 TF-A 端口里写死了：

```c
/* plat/ecnt/en7523/include/platform_def.h */
#define PLAT_ECNT_FIP_OFFSET       (0x800)
#define PLAT_ECNT_FIP_MAX_SIZE     (0x1F800)     /* 0x20000 - 0x800 */
```

以及读取它的地方：

```c
/* plat/ecnt/en7523/bl1/ecnt_bl1_setup.c */
if (flash_read(PLAT_ECNT_FIP_OFFSET, PLAT_ECNT_FIP_MAX_SIZE, ...)
        != FLASH_READ_STATUS_CORRECT)
```

**关键推理**：既然 FIP 在 `0x800`，那 `0x0..0x800` 就是给第一级代码留的。
这段代码不能被覆盖——这是后面 `flash-bl2` 那个陷阱的根源。

### 2.2 反汇编 `0x0..0x800`，确认它是真代码

```bash
dd if=bootloader.bin of=firstblock.bin bs=1 count=$((0x800))
arm-none-eabi-objdump -D -b binary -m arm firstblock.bin
```

HG5580A 的结果：

```
00000000:  e320f000  nop                         ×16
00000040:  e59f00cc  ldr  r0, [pc, #204]
00000044:  ee010f10  mcr  15, 0, r0, cr1, cr0, {0}    ← 写 SCTLR
00000048:  f57ff06f  isb  sy
0000004c:  f1020016  cps  #22                         ← 切处理器模式
00000058:  ee0c0f10  mcr  15, 0, r0, cr12, cr0, {0}   ← 设 VBAR
00000064:  eb000168  bl   0x60c                       ← 调用子程序
00000080:  ee010f11  mcr  15, 0, r0, cr1, cr1, {0}    ← 启用 MMU
```

**这是真实的第一级启动代码，不是填充。**

如果这里全是 `0xFF` 或 `0x00`，说明 ROM 直接从 `0x0` 取指，那时才可以覆盖。
**这一个判断决定后面 `flash-bl2` 用哪条代码路径。**

### 2.3 解析 FIP，看里面有什么

FIP 格式是标准的（ARM 定义）：头部 16 字节 magic `0xAA640001`，然后是
40 字节一条的 entry 表，每条 = 16 字节 UUID + 8 字节 offset + 8 字节 length
+ 8 字节 flags。

```python
import pathlib

d = pathlib.Path('bootloader.bin').read_bytes()
fip = d[0x800:]
assert int.from_bytes(fip[:4], 'little') == 0xAA640001

pos = 16
while pos + 40 <= len(fip):
    head = fip[pos:pos+40]
    if head[:16] == b'\x00' * 16:
        break                      # 零 UUID 表示表结束
    uuid = head[:16]
    off  = int.from_bytes(head[16:24], 'little')
    ln   = int.from_bytes(head[24:32], 'little')
    print(f'uuid={uuid.hex()[:8]}.. off=0x{off:x} len=0x{ln:x}')
    pos += 40
```

HG5580A 的结果（9 条）：

```
uuid=5ff9ec0b.. off=0x400   len=0x1def8     ← BL2 本体
uuid=d6e269ea.. off=0x1e400 len=0x736       ← ?
uuid=827ee890.. off=0x1ec00 len=0xa0e       ← ?
uuid=8ab8becc.. off=0x1f800 len=0x7da       ← ?
uuid=8ad5832a.. off=0x20000 len=0x7ea       ← ?
uuid=e2b20c20.. off=0x20800 len=0x672       ← ?
uuid=8ec4c1f3.. off=0x21000 len=0x682       ← ?
uuid=47d4086d.. off=0x21800 len=0xde42      ← BL31
uuid=d6d0eea7.. off=0x2f800 len=0x46263     ← BL33 (U-Boot)
```

前三个 UUID 是 ARM 标准（`5ff9ec0b` = preloader/BL2，`47d4086d` = BL31，
`d6d0eea7` = BL33）。**中间六个不是标准 UUID**，必须搞清楚。

### 2.4 六个未知 entry 是什么

把它们逐个切出来看内容：

```bash
python3 - <<'EOF'
import pathlib
d = pathlib.Path('bootloader.bin').read_bytes()[0x800:]
# 切出 entry 1..6
...
EOF
strings entry1.bin | head -5
xxd -l 32 entry1.bin
```

结果：

```
entry1: 30 82 07 32 ... "Trusted Boot FW Certificate"
entry2: 30 82 0a 0a ... "Trusted Key Certificate"
entry3: 30 82 07 d6 ... "SoC Firmware Key Certificate"
entry4: 30 82 07 e6 ... "Non-Trusted Firmware Key Certificate"
entry5: 30 82 06 6e ... "SoC Firmware Content Certificate"
entry6: 30 82 06 7e ... "Non-Trusted Firmware Content Certificate"
```

全部以 `30 82` 开头 —— 这是 **ASN.1 DER 序列**的标志，而且名称全是 TF-A
的 TBBR（Trusted Board Boot Requirements）证书槽位。

**结论：原厂镜像启用了安全启动，这六个是完整的证书链。**

### 2.5 这个发现改变什么

如果原厂 BL2 启用了 `TRUSTED_BOARD_BOOT`，它会验证 FIP 里每个镜像的签名。
那我们自编译的 BL2/BL31/U-Boot 没有对应密钥签的证书，**塞不进去**。

破解思路有三条：

| 思路 | 做法 | 风险 |
| --- | --- | --- |
| A | 拿到原厂私钥签自己的镜像 | 不可能 |
| B | 用原厂 BL2 但只换 U-Boot | BL2 会验 BL33 签名，失败 |
| C | **重编 BL2 并关闭验证** | 可行，但需要源码 |

C 是唯一可行的。而且验证方法很直接——**看自编译的 BL2 里有没有证书字符串**：

```bash
strings -n 8 preloader.bin | grep -cE 'Certificate|Trusted|mbedtls'
# 0  → 验证已关闭，无证书的 FIP 可用
# >0 → 验证仍开着
```

HG5580A 实测：我们的 `preloader.bin` 返回 **0**，原厂 `bootloader.bin` 返回
多个命中。**这证明重编的 BL2 关闭了安全启动，整个移植才成立。**

---

## 3. 第三步：找出 BL2 的硬编码地址

这是最容易翻车的地方。BL2 里写死了「UBI 从哪里开始」，如果布局和它不一致，
刷完不启动，而且**串口没有任何有用的错误**。

### 3.1 先看源码的默认值

```c
/* plat/ecnt/en7523/bl2_boot_nand_ubi.c */
#ifdef OVERRIDE_UBI_START_ADDR
#define UBI_START_ADDR      OVERRIDE_UBI_START_ADDR
#else
#define UBI_START_ADDR      0x20000
#endif
```

默认 `0x20000`。但**要确认实际编译进去的是哪个值**。

### 3.2 在二进制里搜索字面量

```bash
python3 - <<'EOF'
import struct
d = open('preloader.bin','rb').read()
for val, name in [(0x20000,'UBI_START_ADDR 默认'),
                  (0x5f00000,'原厂 apps 偏移'),
                  (0x280000,'我们之前的错误值'),
                  (0xe700000,'factory 偏移')]:
    pat = struct.pack('<I', val)
    n = d.count(pat)
    print(f'0x{val:08x} x{n}  {name}')
EOF
```

HG5580A 结果：

```
0x00020000 x1  UBI_START_ADDR 默认      ← 存在
0x05f00000 x0  原厂 apps 偏移           ← 不存在
0x00280000 x0  我们之前的错误值          ← 不存在
0x0e700000 x0  factory 偏移             ← 不存在
```

**`0x20000` 出现一次，其余都没有。确认布局必须让 `ubi` 从 `0x20000` 开始。**

这条验证只花 5 秒，但不做的话可能白刷三次。

### 3.3 还有第二个硬约束

`httpd.c` 里刷 BL2 的处理器：

```c
static int run_bootloader_update(bool bl2)
{
        ...
        mtd = get_mtd_device_nm("bl2");
        if (!mtd_is_partition(mtd) || mtd->offset ||
            mtd->parent->parent || !mtd_uses_pages(mtd) ||
            mtd->size != mtd->erasesize || mtd->erasesize <= 0x800)
                goto out;
```

`mtd->size != mtd->erasesize` → **bl2 分区必须恰好一个擦除块**。

两个约束合起来：

```
bl2 = 0x20000 (128 KiB, 一个擦除块)
ubi 从 0x20000 开始
```

**这就是最终布局的全部依据。** 之前的「2.5 MiB bl2 + ubi@0x280000」同时违反两条。

---

## 4. 第四步：DTS 的 `read-only` 是个陷阱

U-Boot 的 `mtdpart.c` 这样处理 DTS 的 `read-only` 属性：

```c
/*
 * .mask_flags is used to remove flags in allocate_partition(),
 * so when "read-only" is present, we add MTD_WRITABLE to the mask,
 * and so MTD_WRITABLE will be removed on partition allocation
 */
if (ofnode_read_bool(child, "read-only"))
        part.mask_flags |= MTD_WRITEABLE;
```

然后每条写入路径都检查：

```c
/* mtdcore.c */
if (!(mtd->flags & MTD_WRITEABLE))
        return -EPERM;
```

**所以在 U-Boot 的 DTS 里给 `bl2` 标 `read-only`，`flash-bl2` 会在擦除阶段失败。**

而这个失败的表现是：

```
BL2 update failed (-1)
```

**完全不会指向 DTS。**

### 4.1 但内核的 DTS 可以标

关键区分：

| | U-Boot | Linux |
| --- | --- | --- |
| 写 `bl2`？ | 是（`flash-bl2`） | 否 |
| `bl2` 应该标？ | **不标**（可写） | **标**（安全网） |

**「三处 DTS 必须一致」这个直觉是错的。** 正确的是：

```
分区名、偏移、大小  →  必须一致（消费者共享同一份几何）
read-only 标志      →  按消费者各自的需求
```

这一条我一开始理解错了，差点去重编 34 MB 的内核镜像「修正」一个本来正确的东西。

---

## 5. 第五步：把刷写 API 的参数从源码里读出来

不要猜 API。把 `parse_task()` 完整打印出来，逐个分支核对。

### 5.1 操作名清单

```c
} else if (!strcmp(op, "flash-bl2")) {
        job_kind = HTTP_JOB_BL2;
} else if (!strcmp(op, "flash-uboot")) {
        job_kind = HTTP_JOB_FIP;          ← FIP 的真实名字
...
} else {
        return -EINVAL;                    ← 未列出的名字全部拒绝
}
```

用一行命令提取全部合法值：

```bash
grep -o 'strcmp(op, "[a-z-]*")' httpd.c | sed 's/.*"\(.*\)".*/\1/' | sort -u
```

HG5580A：

```
backup boot-production boot-upload command env-set exit flash flash-all
flash-board-data flash-uboot nand-scrub reset ubi-rebuild write
```

**注意没有 `flash-fip`。** 我一开始用的就是这个不存在的名字，会导致第 ⑤ 步
返回 `{"error":"invalid request"}`——而那时 BL2 已经换成只认 UBI 的版本，
UBI 的 `fip` 卷却是空的。**这是必然变砖的状态。**

### 5.2 字段是必需还是可选

```c
if (json_request_init(&r, storage_buf) ||
    json_text(&r, "operation", op, sizeof(op)) ||
    json_uint(&r, "upload_id", &id))
        return -EINVAL;
```

看起来两个都必需，但看 helper 的实现：

```c
static int json_uint(struct http_json_request *r, const char *key, u64 *value)
{
        const jsmntok_t *t = json_field(r, key);

        if (!t) {
                *value = 0;
                return 0;          /* 缺失 → 成功，值为 0 */
        }
        ...
}
```

```c
static int json_text(struct http_json_request *r, const char *key,
                     char *out, size_t size)
{
        const jsmntok_t *t = json_field(r, key);

        if (!t || t->type != JSMN_STRING || !size)
                return -EINVAL;    /* 缺失 → 失败 */
        ...
}
```

**结论：`operation` 必需，`upload_id` 可选。** 所以
`{"operation":"ubi-rebuild"}` 不带 upload_id 是合法的。

**如果不读 helper 就只看调用点，会误判成「两个都必需」而去加多余的字段。**

### 5.3 两个端点，两个大小限制

```c
/* httpd_post_begin */
if (!strcmp(uri, "/api/upload") || !strcmp(uri, "/api/upload-all-flash")) {
        ...
        post_state.kind = HTTP_POST_UPLOAD;        /* 大文件 */
} else if (!strcmp(uri, "/api/task") && content_len < sizeof(storage_buf)) {
        post_state.kind = HTTP_POST_TASK;          /* 只接受 < 2048 */
} else {
        goto reject;
}
```

`HTTPD_STORAGE_LEN = 2048`。**固件镜像必须发到 `/api/upload`，命令发到
`/api/task`。** 搞反的话，最小的载荷（131 KB）也超 2048 的 64 倍，直接被拒。

### 5.4 上传成功返回什么

```c
/* httpd_post_finished */
upload_id++;
phase = "ready";
strlcpy(response_uri, ret ? "/api/error" : "/api/reply", ...);
```

**不是返回 JSON body，是改写响应 URI 到 `/api/reply`。** 客户端跟随重定向后
才拿到 `build_result()` 的输出，里面含 `upload_id` 和 `phase`。

**判断成功应该看 `phase == "ready"`，而不是 `upload_id` 非零** ——
`upload_id` 初始化是 `get_timer(0)`，可能为 0。

---

## 6. 第六步：验证编译产物，不验证源码

这是贯穿始终的原则。源码改了不代表产物变了。

### 6.1 检查固件镜像里的 DTB

```bash
# 从 FIT 里提取 payload 1（设备树）
dumpimage -T flat_dt -p 1 -o inner.dtb sysupgrade.itb
dtc -I dtb -O dts inner.dtb | grep -A2 'label = "bl2"'
```

**HG5580A 踩过这个坑**：DTS 源码在 17:0x 改了布局，但镜像编译时间戳是
16:26，里面还是旧布局（`bl2=0x280000`）。如果直接刷，会出现
「BL2 找 0x20000，内核说 0x280000」的不一致。

### 6.2 检查 U-Boot 内嵌的 DTB

`u-boot.bin` 里可能同时有内嵌 DTB 和追加 DTB：

```bash
# 找所有 FDT 魔数
python3 -c "
d = open('u-boot.bin','rb').read()
M = b'\xd0\x0d\xfe\xed'
i = 0
while True:
    j = d.find(M, i)
    if j < 0: break
    print(f'0x{j:x}')
    i = j + 1
"
```

HG5580A 结果：`u-boot.bin` 在 `0xd8250` 有一个，`u-boot-52.bin` 在 `0xdbb30`
又追加了一个。`cmp` 验证**两者字节完全相同**，所以不冲突。

**但如果内容不同，就会是严重问题**——运行时的 U-Boot 用内嵌那个。

### 6.3 检查 FIT 的 `compatible` 匹配

`validate_firmware_fit()` 在写入前做这个检查：

```c
compatible = fdt_getprop(image_data, 0, "compatible", &compatible_len);
if (!compatible || ... || !of_machine_is_compatible(compatible)) {
        printf("Firmware target '%.*s' does not match this board.\n", ...);
        goto out;
}
```

**要求 FIT 内 DTB 的 root `compatible` 与 U-Boot 自己的有交集。**

验证：

```bash
# U-Boot 的
dtc -I dtb -O dts u-boot.dtb | grep compatible | head -1
# 固件 FIT 的
dtc -I dtb -O dts inner.dtb | grep compatible | head -1
```

HG5580A 两边都是 `"fiberhome,hg5580a-ubi\0airoha,an7583"`，匹配。

**这个检查失败的表现是**：第 ⑥ 步报
`Firmware target 'xxx' does not match this board`——而那时前五步都已经写完了。

---

## 7. 第七步：验证工具本身

这一条最容易被忽略，也最阴险。

**我用来自动验证的脚本，本身出过 5 次解析错误：**

| # | 工具 | 错误 | 后果 |
| --- | --- | --- | --- |
| 1 | 布局校验 | 正则用 `\n\t\t\};` 找节点结束，dtc 实际输出 5 个 tab | 只匹配到第一个分区 |
| 2 | 内存预算 | `SAFE_END=0x9ea89370` 字符串参与数值比较 | 所有载荷误报超标 |
| 3 | 镜像校验 | 单引号外多个 `"` | bash 语法错误，脚本跑不完 |
| 4 | 操作名提取 | `grep -oE -- "-operation '..."` 把前缀当结果 | 误报非法操作名 |
| 5 | 板级数据 | `cal[:15] != b'fiberhomebdbob'`（14 字节字符串切 15） | 正确数据误报错误 |

**共同点：都是「验证工具没被验证」。**

防御办法：

1. **正则不要依赖缩进**。解析 DTS 用花括号配对，不用 `\n\t+`。
2. **数值比较前先转换**。bash 里 `$((0x...)` 转成十进制。
3. **写完后立刻用 `bash -n` / `Parser::ParseFile` 做语法检查**。
4. **让工具输出中间结果**，不只输出 PASS/FAIL——便于发现「匹配了但匹配错了」。

第 4 条特别重要。比如分区解析器应该打印出每个分区的名字、偏移、大小、可写性
四列，而不是只打印 `OK`。**看到中间值，才能发现解析错位。**

---

## 8. 一个隐蔽的脚本级错误

```powershell
throw "$label: no task result"
```

在 PowerShell 里，`"$label:"` 被解析成 **drive-qualified 变量引用**
（像 `$env:PATH` 那样），`:` 后必须是合法变量名字符，否则：

```
变量引用无效。':' 后面的变量名称字符无效。请考虑使用 ${} 分隔名称。
```

**这是编译期错误，脚本一行都不会执行。**

修复：

```powershell
throw "${label}: no task result"
```

**而我自己写检查命令时又踩了同一个坑：**

```powershell
"=== 检查其他 $var: 模式 ==="     # 同样报错
```

说明这类错误确实隐蔽。**防御：脚本写完后一定跑一次语法检查。**

```powershell
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    $path, [ref]$null, [ref]$errs)
if ($errs) { $errs | ForEach-Object { $_.Message } }
```

---

## 9. 方法论总结

### 9.1 一切结论都要有源码或二进制证据

| 结论 | 证据类型 | 具体位置 |
| --- | --- | --- |
| FIP 在 `0x800` | 源码常量 | `platform_def.h` `PLAT_ECNT_FIP_OFFSET` |
| `0x0..0x800` 是真代码 | 反汇编 | `mcr 15,0,r0,cr1,cr0,0` 等指令 |
| 原厂开了安全启动 | 字符串 | 六个 `*Certificate` |
| 我们的 BL2 关了 | 字符串计数 = 0 | `strings \| grep -c Certificate` |
| UBI 从 `0x20000` | **二进制字面量** | `struct.pack('<I',0x20000)` 命中 |
| bl2 必须一个擦除块 | 源码条件 | `mtd->size != mtd->erasesize` |
| `read-only` 阻止写入 | 源码机制 | `mask_flags \|= MTD_WRITEABLE` |
| 上传必须走 `/api/upload` | 源码分派 | `content_len < sizeof(storage_buf)` |
| FIP 操作名叫 `flash-uboot` | 源码字符串表 | `grep -o 'strcmp(op, "…")'` |

**「我觉得应该是这样」不算证据。**

### 9.2 区分「必须一致」和「可以不同」

```
分区名 / 偏移 / 大小  →  所有消费者必须一致
read-only 标志        →  按消费者各自需求
```

**把「一致性」当成教条，会做出错误的修改。**

### 9.3 验证产物，不验证源码

```bash
# 错：只看源码
grep 'reg = <0x20000' an758x-parts.dtsi    ✅

# 对：从产物里反推
dumpimage -T flat_dt -p 1 -o x.dtb image.itb
dtc -I dtb -O dts x.dtb | grep -A2 'label = "ubi"'    ✅
```

源码改了 → 需要重编 → 重编了 → 需要验证产物。**这条链每一步都可能断。**

### 9.4 危险操作前，先做「会不会变砖」判断

每次写 flash 之前问：

```
这一步失败，设备还能起来吗？
  能  → 可以直接做
  不能 → 先确认后面每一步都准备好了，再一起做
```

HG5580A 的刷写顺序正是按这个原则排的：

```
① flash-bl2        ← 关键点：之后设备只能从 UBI 启动
② ubi-rebuild      ┐
③ flash-board-data │  必须全部成功后设备才能起来
④ flash-board-data │
⑤ flash-uboot      ┘
⑥ flash
```

**① 之后如果 ②-⑤ 有任何一步失败，设备就起不来了。** 所以这五步的所有前置条件
必须在执行 ① 之前验证完——这就是 `preflight.sh` 存在的原因。

### 9.5 硬件依赖的部分要明确划出来

有些事无论怎么努力都做不了：

```
❌ 从运行中的原厂固件远程重启进 U-Boot
   - 串口 7 种波特率全部静默
   - Magic SysRq 无响应（CONFIG_MAGIC_SYSRQ_SERIAL 未开）
   - 44 个 CGI 路径全部 forbidden（需认证）
   - 唯一可用的 /cgi-bin/ajax 只接受 fhencrypt 加密体

❌ 没有光信号时测 PON 速率
   - pon0 的 carrier 需要物理光信号
```

**识别出这类边界，比在边界内反复尝试更有价值。** 前者花 5 分钟得出「必须物理
断电」，后者可能花 5 小时得出同样的结论。

---

## 10. 时间分配的经验

回看整个项目，时间大致是这样花的：

| 阶段 | 占比 | 说明 |
| --- | --- | --- |
| 摸清启动链 | 20% | 备份、拆解 bootloader、确认安全启动、找硬编码地址 |
| 构建系统打通 | 30% | WSL 环境、依赖、0 字节污染、内存不足 |
| **发现并修复致命配置错误** | **30%** | 7 个必然失败的 bug |
| 文档与工具 | 20% | preflight 审计、恢复手册 |

**第三项占比很高，而且全是「不读源码就发现不了」的类型。**

如果重来一次，我会把「读源码核对每个 API 参数」提到构建之前——那 7 个 bug
里有 5 个可以在第一天就发现。

---

## 附录：HG5580A 的最终事实

```
SoC          Airoha AN7583, 2× Cortex-A53
DRAM         512 MiB @ 0x80000000
闪存         256 MiB SPI-NAND
             SkyHigh S35ML02G300 (mfr 0x01, dev 0x25, OOB 128)
             或 FORESEE F35SQB002G (mfr 0xCD, dev 0x52, OOB 64)
擦除块       0x20000 (128 KiB)
页           2048 B
序列口       UART1 0x1fbf0000, 115200 8N1
PON          Airoha UX3363 paged BOSA, I2C 0x51
2.5G PHY     Motorcomm YT8821, MDIO 0x07, gdm3
Switch       MediaTek MT7530, gdm1

启动链
  ROM → 0x800 的 FIP → UUID[0] = BL2 → UBI 的 "fip" 卷
      → UUID[1] BL31 + UUID[2] U-Boot → UBI 的 "fit" 卷 → 内核

分区布局
  bl2      0x00000000  0x00020000   可写
  ubi      0x00020000  0x0e6e0000
  factory  0x0e700000  0x00500000   只读
  bosacal  0x0ec00000  0x00020000   只读
  identity 0x0ec20000  0x00020000   只读
```
