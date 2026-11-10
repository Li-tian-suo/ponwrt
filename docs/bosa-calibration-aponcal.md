# APONCAL 容器格式：128 字节头 + 两处 CRC-32

> 这份文档替代早前靠反汇编写出的版本。
>
> 早前那版有 **8 处错误**，其中一个致命：漏掉了两处 CRC-32 校验，
> 导致构造出的校准块永远被判 `invalid`。
>
> 错误全部来自"只读反汇编、没读源码"。源码一直在
> `feeds/pon_drivers/airoha-pon-frontends/src/` 里。

---

## 1. 源码位置

```
feeds/pon_drivers/airoha-pon-frontends/
├── README.md
└── src/
    ├── airoha-paged-bosa.h              枚举与结构
    ├── airoha-paged-bosa-main.c         probe / bosa_load_calibration
    ├── airoha-paged-bosa-ux3363.c       ux3363_identify / ux3363_apply
    └── airoha-paged-bosa-gn28l95.c      另一款模块
```

README 只有一句关键信息：

| Provider | Devices | Calibration source |
| --- | --- | --- |
| `airoha-en7572` | EN7572 | 512-byte BOB NVMEM cell |
| `airoha-paged-bosa` | GN28L95, UX3363 | `APONCAL` NVMEM cell or board firmware |

---

## 2. 常量（全部在 main.c 头部）

```c
#define AIROHA_BOSA_CAL_MAGIC       "APONCAL\0"
#define AIROHA_BOSA_CAL_VERSION     1
#define AIROHA_BOSA_CAL_HEADER_SIZE 0x80
#define AIROHA_BOSA_CAL_NATIVE      1
```

```c
/* airoha-paged-bosa.h */
enum airoha_bosa_calibration_id {
	AIROHA_BOSA_CAL_GN28L95 = 1,
	AIROHA_BOSA_CAL_UX3363 = 2,
};
```

**`calibration_id` 从 1 开始，所以 0 是非法值。** 早前填 0，
`bosa_chip_by_id(0)` 返回 NULL，走 `-ENODEV` 分支。

---

## 3. 完整头结构

| 偏移 | 类型 | 值 | 含义 |
| --- | --- | --- | --- |
| `0x00` | `char[8]` | `"APONCAL\0"` | 魔数 |
| `0x08` | `u16` | `1` | 版本 |
| `0x0a` | `u16` | `0x0080` | 头长度 |
| `0x0c` | `u32` | `2` | `calibration_id`（UX3363） |
| `0x10` | `u32` | `1` | `NATIVE` 标志 |
| `0x14` | `u32` | `0x780` | 载荷长度 |
| `0x18` | `u32` | CRC | **载荷 CRC-32** |
| `0x1c..0x7b` | — | 0 | 保留 |
| `0x7c` | `u32` | CRC | **头部 CRC-32**（覆盖 `0x00..0x7b`） |
| `0x80` | — | — | 载荷起点 |

---

## 4. 校验逻辑（bosa_load_calibration 全文）

```c
static int bosa_load_calibration(struct airoha_paged_bosa *bosa)
{
	struct device *dev = &bosa->client->dev;
	struct nvmem_cell *cell;
	u8 *data;
	u32 header_crc, payload_crc, payload_length;
	u16 header_size, version;
	size_t cell_size;
	int ret = 0;

	cell = devm_nvmem_cell_get(dev, "calibration");
	if (IS_ERR(cell))
		return PTR_ERR(cell);
	data = nvmem_cell_read(cell, &cell_size);
	if (IS_ERR(data))
		return PTR_ERR(data);

	if (cell_size < AIROHA_BOSA_CAL_HEADER_SIZE ||
	    memcmp(data, AIROHA_BOSA_CAL_MAGIC, 8)) {
		ret = -EINVAL;
		goto out;
	}

	version        = get_unaligned_le16(data + 0x08);
	header_size    = get_unaligned_le16(data + 0x0a);
	bosa->calibration_id = get_unaligned_le32(data + 0x0c);
	payload_length = get_unaligned_le32(data + 0x14);
	header_crc     = get_unaligned_le32(data + 0x7c);

	if (version != AIROHA_BOSA_CAL_VERSION ||
	    header_size != AIROHA_BOSA_CAL_HEADER_SIZE ||
	    get_unaligned_le32(data + 0x10) != AIROHA_BOSA_CAL_NATIVE ||
	    payload_length > cell_size - header_size ||
	    (crc32_le(~0U, data, 0x7c) ^ ~0U) != header_crc) {
		ret = -EINVAL;
		goto out;
	}

	payload_crc = get_unaligned_le32(data + 0x18);
	if ((crc32_le(~0U, data + header_size, payload_length) ^ ~0U) !=
	    payload_crc) {
		ret = -EBADMSG;
		goto out;
	}

	if (!bosa_chip_by_id(bosa->calibration_id)) {
		ret = -ENODEV;
		goto out;
	}

	bosa->calibration = devm_kmemdup(dev, data + header_size,
	                                 payload_length, GFP_KERNEL);
	if (!bosa->calibration) {
		ret = -ENOMEM;
		goto out;
	}
	bosa->calibration_length = payload_length;
out:
	kfree(data);
	return ret;
}
```

### 状态映射

```c
if (!calibration_ret) {
	bosa->calibration_state = AIROHA_PON_FRONTEND_CALIBRATION_READY;
} else if (calibration_ret == -ENOENT || calibration_ret == -ENODEV ||
           calibration_ret == -ENODATA) {
	bosa->calibration_state = AIROHA_PON_FRONTEND_CALIBRATION_MISSING;
} else {
	bosa->calibration_state = AIROHA_PON_FRONTEND_CALIBRATION_INVALID;
}
```

所以：

| 返回 | 状态 |
| --- | --- |
| `0` | `ready` |
| `-ENOENT` / `-ENODEV` / `-ENODATA` | `missing` |
| `-EINVAL` / `-EBADMSG` / `-ENOMEM` | **`invalid`** |

**设备上看到的是 `invalid`，说明走到的是 `-EINVAL` 或 `-EBADMSG`。**

`-ENODEV`（`calibration_id` 无效）会显示 `missing` 而不是 `invalid` ——
这一点排除了"只是 id 填错"的可能，说明头部校验先失败了。

---

## 5. CRC 算法：就是标准 CRC-32

```c
#include <linux/crc32.h>
(crc32_le(~0U, data, 0x7c) ^ ~0U)
```

`crc32_le` 是 `linux/crc32.h` 的反射多项式 CRC-32（IEEE 802.3），
初始值 `~0U`，结果再 `^ ~0U`。

**这与 `zlib.crc32` 完全等价** —— zlib 内部也做同样的初始和最终反转。
所以 Python 里直接：

```python
import zlib
header_crc = zlib.crc32(bytes(hdr[0x00:0x7c])) & 0xFFFFFFFF
payload_crc = zlib.crc32(payload) & 0xFFFFFFFF
```

不需要自己实现位运算。

---

## 6. 载荷：1920 字节寄存器镜像

```c
/* airoha-paged-bosa-ux3363.c */
#define UX_CALIBRATION_LENGTH 0x780

static int ux3363_apply(struct airoha_paged_bosa *bosa, const u8 *data,
                        size_t length)
{
	u8 value;
	int ret;

	if (length != UX_CALIBRATION_LENGTH)
		return -EINVAL;

	/* Page 0x80, register 0xb7 bit 0 enables volatile configuration writes.
	 * The payload uses the chip's native 0x780-byte register image. */
	ret = airoha_paged_bosa_select_page(bosa, 0x80);
	...
```

### 完整切片表

| 载荷偏移 | 长度 | 目标页 | 起始寄存器 |
| --- | --- | --- | --- |
| `0x100..0x17A` | 123 | `0x00` | `0x00` |
| `0x200..0x26E` | 111 | `0x80` | `0x80` |
| `0x280..0x2E8` | 105 | `0x81` | `0x80` |
| `0x300..0x368` | 105 | `0x82` | `0x80` |
| `0x380..0x3D3` | 84 | `0x84` | `0x80` |
| `0x3D6..0x3DD` | 8 | `0x84` | `0xD6` |
| `0x3E0..0x3EA` | 11 | `0x84` | `0xE0` |
| `0x400..0x468` | 105 | `0x83` | `0x80` |

**`0x000..0x0FF` 和 `0x469..0x77F` 驱动完全不读。**

源码注释还解释了 `0xD6` 和 `0xE0` 为什么不是连续的：

```c
/* Registers 0xd4–0xd5 and 0xde–0xdf are reserved by the chip. */
ret = ux3363_write_range(bosa, 0x84, 0xd6, data + 0x3d6, 8);
ret = ux3363_write_range(bosa, 0x84, 0xe0, data + 0x3e0, 11);
```

### 写入前后动作

```c
/* 前置：使能易失写 */
read   page 0x80 reg 0xb7
if (!(value & BIT(0)))
        write  page 0x80 reg 0xb7 = value | BIT(0)
        sleep  10–11 ms

... 八段切片 ...

/* 中段：重新选页 0x80，逐寄存器写 111 字节 */
for (value = 0; value < 111; value++) {
        reg  = 0x80 + value;          /* 0x80 .. 0xEE */
        byte = data[0x200 + value];
        if (reg == 0xb7)
                byte |= BIT(0);
        write page 0x80 reg reg = byte
        sleep (reg == 0xb7 ? 10–11 ms : 1–1.5 ms)
}

/* 收尾：TX_CONTROL 上做 1→0 脉冲 */
read   reg 0x6e
write  reg 0x6e = value | BIT(6)
sleep  10–11 ms
write  reg 0x6e = value & ~BIT(6)
sleep  10–11 ms
```

---

## 7. 早前的 8 处错误

| # | 早前记录 | 源码真相 | 后果 |
| --- | --- | --- | --- |
| 1 | 头部 24 字节够用 | 需要 128 字节 | `cell_size < 0x80` → `-EINVAL` |
| 2 | 无 `header_crc` | `0x7c` 处 CRC 覆盖 `0x00..0x7b` | `-EINVAL` |
| 3 | 无 `payload_crc` | `0x18` 处 CRC 覆盖载荷 | `-EBADMSG` |
| 4 | `calibration_id = 0` | 必须 `2`（UX3363） | `-ENODEV` → `missing` |
| 5 | `0x000..0x0B7` 是切片 | 驱动**不读**这段 | 写错位置 |
| 6 | `0x200` → reg `0x00`，110 B | reg `0x80`，**111** B | 写错位置 |
| 7 | `0x3D6` → reg `0x56` | reg **`0xD6`** | 写到保留寄存器 |
| 8 | `0x3E0` → reg `0x60` | reg **`0xE0`** | 写到保留寄存器 |

第 7、8 项的原因：反汇编里是 `mov w2, #0xffffffd6`，
**符号扩展后取低 8 位是 `0xD6`，不是 `0x56`。** 我算错了。

第 5、6 项的原因：把循环 `data[0x200 + value]` 误读成 `data[value]`，
凭空造出一个不存在的切片，同时把真实切片的起点和长度都算错。

---

## 8. 一个决定性的诊断依据

设备上看到的是：

```
airoha-paged-bosa 0-0051: UX3363 frontend registered, ID 55583333363331,
                          calibration invalid
```

**`invalid` 而不是 `missing`** —— 这个区别本身就是线索：

- 如果是 `calibration_id` 错 → `-ENODEV` → 显示 `missing`
- 显示 `invalid` → 只能走 `-EINVAL` 或 `-EBADMSG` → **头部结构或 CRC 错**

所以早前的 24 字节裸头（无 CRC、id=0）理论上应该显示 `missing`，
但实测显示 `invalid`，说明 `memcmp(data, "APONCAL", 8)` 之后更早的
`cell_size < 0x80` 或魔数比较就失败了 —— 因为那个裸头只有 24 字节。

**这条推理链在源码里闭合了。**

---

## 9. 构造与验证

工具 `tools/build-aponcal.py` 按上面的规范生成容器，
并在输出里逐条复现 `bosa_load_calibration` 的每一个判断：

```
header:
  0x00  magic   b'APONCAL\x00'
  0x08  u16     1            version
  0x0a  u16     0x0080       header size
  0x0c  u32     2            calibration_id (UX3363)
  0x10  u32     1            native
  0x14  u32     1920         payload length
  0x18  u32     0x6a736a00   payload crc32
  0x7c  u32     0x59030200   header crc32

bosa_load_calibration checks:
  [OK] cell_size >= header_size
  [OK] magic == APONCAL\0
  [OK] version == 1
  [OK] header_size == 0x80
  [OK] field_0x10 == NATIVE (1)
  [OK] payload_len <= cell_size - header_size
  [OK] header crc32 matches
  [OK] payload crc32 matches
  [OK] calibration_id == 2 (2)
```

支持三种载荷来源：

```
--payload zero              全零，用于先验证容器格式
--payload FILE              1920 字节寄存器镜像（从模块读回）
（默认）                     厂商 fiberhomebdbob 表，近似填充
```

---

## 10. 分层验证策略

不要一次就指望 PON 起来。按这个顺序：

```
第 1 层：--payload zero
        目标：calibration 变成 ready
        证明：容器格式正确（魔数、版本、长度、两处 CRC、chip id）
        失败：说明头部还有问题，回到 §4 逐条对

第 2 层：--payload （厂商表近似填充）
        目标：ready 且不报 I2C 错误
        证明：八段切片都能写进模块
        失败：大概率是某个页/寄存器映射错，看 dmesg 的 I2C 错误码

第 3 层：--payload 从模块读回的镜像
        目标：ready 且 pon0 carrier=1
        证明：载荷语义正确
        失败：载荷内容不对，需要另一台 calibrated 设备作参照
```

**每一层都产出一个明确的、可复现的结论。**
这是把"PON 不起来"这种模糊问题拆成可判定步骤的唯一办法。

---

## 11. 方法论教训

这个项目里最贵的一课：

> **反汇编是最后手段，不是第一手段。**

我花了大量时间反汇编 `airoha-paged-bosa.ko`，解出了大致结构，
但因为反汇编不会显示：

- 宏定义（`AIROHA_BOSA_CAL_*`）
- 枚举值（`CAL_GN28L95 = 1`，所以 0 非法）
- 源码注释（"Registers 0xd4–0xd5 and 0xde–0xdf are reserved"）
- `crc32_le()` 的实际语义（看起来只是普通函数调用）

所以漏掉了整整两个校验步骤，解出的切片表也有 4 处偏移错。

**源码在 `feeds/pon_drivers/` 里，第一次搜索就应该找到它。**

搜索路径记下来：

```
grep -rla 'APONCAL' /root/build/<target>/feeds/
find /root/build/<target>/feeds -name '*<driver>*'
```

只要目标串是驱动里的宏或字符串，`grep -a`（二进制也搜）就能定位到源码文件。
