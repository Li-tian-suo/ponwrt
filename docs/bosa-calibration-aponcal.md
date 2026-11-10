# BOSA 光学校准：从 `fiberhomebdbob` 到 `APONCAL`

> 记录一个只靠日志猜不出来的问题：驱动报告 `calibration invalid`，
> 而校准数据明明写进去了、位置也对、型号也识别了。
>
> 结论来自反汇编 `airoha-paged-bosa.ko`，不是猜测。

---

## 1. 现象

刷完单 UBI 布局后，PonWrt 正常启动，`pon0`、`omci0`、`oam0` 全部出现，
MAC 地址正确，驱动栈全部绑定：

```
airoha_en7572              16384  0
airoha_paged_bosa          16384  1        ← refcount 非零，说明绑定了
airoha_pon_frontend_core   12288  3        airoha_paged_bosa,airoha_en7572,airoha_xpon
airoha_xpon                77824  0
```

但内核日志里有一句：

```
[12.321264] airoha-paged-bosa 0-0051: UX3363 frontend registered,
            ID 55583333363331, calibration invalid
```

同时 `ponctl status` 显示：

```
[frontend]
  calibration: invalid
  rx_power_dbm: -40.00
[line]
  lifecycle: stopped
  optical_signal: 0
  xgtc_sync: hunt
[registration]
  onu_state: O1
  serial_configured: 0
```

因果链很明确：

```
calibration invalid → 驱动拒绝启动（lifecycle: stopped）
                    → 序列号无法生效（serial_configured: 0）
                    → PON 完全不工作
```

**先要确认的是：校准数据到底有没有被读到。**

---

## 2. 排除：数据是读到了，位置也对

### 2.1 卷里的内容

```
# hexdump -C /dev/ubi0_3
00000000  00 00 41 50 4f 4e 43 41  4c 00 01 00 80 00 00 00  |..APONCAL.......|
```

早期版本里是厂商表：

```
00000000  ff ff 66 69 62 65 72 68  6f 6d 65 62 64 62 6f 62  |..fiberhomebdbob|
00000010  00 00 32 30 32 34 30 34  32 39 31 35 35 39 56 42  |..202404291559VB|
```

`fiberhomebdbob` 从卷偏移 `0x02` 开始，正好对应 DTS：

```dts
ubi-volume-bosa {
	volname = "bosa";
	nvmem-layout {
		compatible = "fixed-layout";
		bosa_calibration: calibration@2 { reg = <0x2 0x800>; };
	};
};
```

### 2.2 phandle 链也是对的

设备上实测：

```
/proc/device-tree/.../partition@20000/volumes/ubi-volume-bosa/
    nvmem-layout/calibration@2/phandle = 00 00 00 1e

/sys/bus/i2c/devices/0-0051/of_node/nvmem-cells = 00 00 00 1e
```

两边都是 `0x1e`，**驱动确实通过 bosa 卷读取校准**。

### 2.3 型号识别来自硬件，不是校准

日志里的 `ID 55583333363331` 一度被误认为是从校准数据里读出的型号。
反汇编 `ux3363_identify` 后否定了这个假设：

```asm
0000000000000fe0 <ux3363_identify>:
     ffc:  mov  w1, #0xffffff87          ; page -121 = 0x87
    1000:  bl   airoha_paged_bosa_select_page
    102c:  add  x2, sp, #0x39            ; buffer
    1034:  mov  x3, #0x7                 ; read 7 bytes
    1038:  mov  w1, #0xffffff80          ; register 0x80
    103c:  bl   airoha_paged_bosa_read

    1060:  ldur w1, [sp, #57]            ; first 4 bytes
    1064:  mov  w0, #0x5855              ; 'U','X'
    1068:  movk w0, #0x3333, lsl #16     ; '3','3'
    106c:  cmp  w1, w0                   ; == "UX33" ?
    1070:  b.ne fail

    1074:  ldurh w1, [sp, #61]           ; next 2 bytes
    1078:  mov  w0, #0x3336              ; '3','6'
    107c:  cmp  w1, w0                   ; == "36" ?
    1080:  b.ne fail
```

**这段代码走的是 I2C 硬件路径（页 `0x87`、寄存器 `0x80`），与校准卷完全无关。**
所以 `ID 55583333363331`（ASCII `UX33631`）是光模块硬件的真实回应。

**结论：校准确实被读取了，位置正确，但内容格式不被接受。**

---

## 3. 真正的契约：`APONCAL` 头

反汇编 `bosa_probe`，在 `nvmem_cell_read` 之后有一整段校验：

```asm
   134:  ldr  x2, [sp]              ; cell 长度
   138:  cmp  x2, #0x7f
   13c:  b.ls FAIL                  ; 长度必须 > 127

   140:  ldr  x3, [x0]              ; 前 8 字节
   144:  mov  x1, #0x5041           ; 'A','P'
   148:  movk x1, #0x4e4f, lsl 16   ; 'O','N'
   14c:  movk x1, #0x4143, lsl 32   ; 'C','A'
   150:  movk x1, #0x4c,   lsl 48   ; 'L','\0'
   154:  cmp  x3, x1
   158:  b.ne FAIL                  ; 魔数 "APONCAL\0"

   15c:  ldrh w3, [x0, #10]
   160:  ldr  w4, [x0, #12]
   164:  ldrh w1, [x0, #8]
   168:  cmp  w3, #0x80             ; [0x0a] == 0x80
   16c:  str  w4, [x19, #136]       ; [0x0c] 存入 priv+136
   170:  ccmp w1, #0x1, #0x0, eq    ; [0x08] == 1
   174:  b.ne FAIL

   178:  ldr  w1, [x0, #16]
   17c:  cmp  w1, #0x1
   180:  b.ne FAIL                  ; [0x10] == 1

   184:  sub  x2, x2, #0x80         ; 剩余 = cell_len - 0x80
   18c:  ldr  w25, [x0, #20]
   190:  cmp  x25, x2
   194:  b.ls OK                    ; [0x14] <= cell_len - 0x80
   198:  kfree; return -EINVAL
```

### 结构定义（小端，偏移相对 cell 起点）

| 偏移 | 类型 | 要求 | 含义 |
| --- | --- | --- | --- |
| `0x00` | `char[8]` | `"APONCAL\0"` | 魔数 |
| `0x08` | `u16` | `1` | 版本 |
| `0x0a` | `u16` | `0x0080` | 头部长度 |
| `0x0c` | `u32` | 任意 | 存入 priv+136 |
| `0x10` | `u32` | `1` | 标志 |
| `0x14` | `u32` | `<= cell_len - 0x80` | 载荷长度 |
| `0x80` | — | — | 载荷起点 |

**厂商的 `fiberhomebdbob` 表第一字节是 `0x66`（`'f'`），而驱动要的是 `0x41`（`'A'`）。
一个字节都不匹配，所以走到 `FAIL`，状态置为 `CALIBRATION_INVALID`。**

驱动模块里的字符串清单也印证了这一点：

```
AIROHA_PON_FRONTEND_CALIBRATION_READY
AIROHA_PON_FRONTEND_CALIBRATION_MISSING
AIROHA_PON_FRONTEND_CALIBRATION_INVALID
AIROHA_PON_FRONTEND_CALIBRATION_NOT_REQUIRED
AIROHA_PON_FRONTEND_CALIBRATION_UNKNOWN
```

`MISSING` 与 `INVALID` 是两个不同状态：前者表示 cell 不存在，后者表示读到了但内容不合格。
我们拿到的是 `INVALID`，正好对应"读到了、格式不对"。

---

## 4. 一个容易忽略的边界条件

`[0x14] <= cell_len - 0x80` 这一条最初被算错了。

DTS 声明 `reg = <0x2 0x800>`，所以 `cell_len = 0x800 = 2048`。
那么边界是 `2048 - 128 = 1920`。

**第一版构造脚本把 `[0x14]` 填成了 131072**（整个厂商表的大小），
即使魔数正确也会在最后一步被拒绝：

```
[0x14] 131072 <= 1920  →  false
```

修正为 `payload_len = min(len(vendor_table), 1920) = 1920` 才通过。

**教训：每个比较都要还原它的两个操作数，不能只看"有检查"。**

---

## 5. 最小载荷：能让 probe 过，但不等于能用

因为 `[0x14]` 允许为 0（`0 <= 1920` 成立），**一个 24 字节的裸头就能让
`bosa_probe` 通过**：

```
41 50 4f 4e 43 41 4c 00   "APONCAL\0"
01 00                     version = 1
80 00                     header  = 0x80
00 00 00 00               field_0c
01 00 00 00               field_10 = 1
00 00 00 00               payload_len = 0
```

在设备上可以直接用 `printf` 的八进制转义生成，不需要传输文件：

```sh
printf '\101\120\117\116\103\101\114\000\001\000\200\000\000\000\000\000\001\000\000\000\000\000\000\000' > /tmp/hdr.bin
```

这条命令能在串口控制台上一次敲完，对没有网络或没有 `base64` 的环境特别有用。

**重要限定：这个 24 字节头只解决 `bosa_probe`，不解决 PON。**

反汇编 `ux3363_apply` 后才知道它第一件事就是（见 §10.1）：

```asm
10b8:  cmp  x2, #0x780
10bc:  b.ne FAIL            ; 载荷长度必须精确 1920
```

所以裸头会让状态变成 `calibration: ready`，但 `ux3363_apply` 照样返回 `-EINVAL`，
光模块的页不会被编程，PON 仍然起不来。

**裸头的用途是分阶段验证**：先确认头部契约理解正确（probe 过），
再去解决载荷内容（1920 字节的模块 EEPROM 镜像，见 §10）。

---

## 6. 写入 UBI 卷的正确方式

### 6.1 直接 dd 会失败

```
# dd if=/tmp/hdr.bin of=/dev/ubi0_3 bs=1 seek=2 conv=notrunc
dd: error writing '/dev/ubi0_3': Operation not permitted
```

UBI 卷不是普通块设备，**不能按偏移随机写**。即使卷状态是 `dynamic`、`State: OK`，
普通写路径依然被拒。

### 6.2 用 `ubiupdatevol` 整卷替换

```sh
# 生成一个完整尺寸的镜像
dd if=/dev/zero of=/tmp/bosa.bin bs=1024 count=256     # 262144 字节

# 把 APONCAL 头放到卷偏移 2（对应 calibration@2）
dd if=/tmp/hdr.bin of=/tmp/bosa.bin bs=1 seek=2 conv=notrunc

# 整卷写入
ubiupdatevol /dev/ubi0_3 /tmp/bosa.bin
```

`ubiupdatevol` 会先擦除整个卷再顺序写入，这是唯一被允许的写入方式。

### 6.3 校验

```
# hexdump -C /dev/ubi0_3 | head -2
00000000  00 00 41 50 4f 4e 43 41  4c 00 01 00 80 00 00 00  |..APONCAL.......|
00000010  00 00 01 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
```

`APONCAL` 出现在卷偏移 `0x02`，即 `calibration@2` 的 cell 起点。正确。

---

## 7. 让新校准生效

`rmmod airoha_paged_bosa` 会失败：

```
unloading the module failed
```

因为 `pon0`、`omci0`、`oam0` 都占着它（refcount = 1），且即使 `ip link set ... down`
也不会释放。

**必须重启。** 但重启方式很重要，见下一节。

---

## 8. 一个反面教材：不要用 `reboot`

执行 `reboot` 之后设备完全静默：

```
串口 115200 / 57600 / 38400 / 9600   全部静默
192.168.0.1                          no reply
192.168.1.1                          no reply
串口适配器 USB-SERIAL CH340 (COM4)    status=OK（硬件本身没问题）
```

原因：**Linux 的 `reboot` 走 PSCI 热复位，跳过了 BL2 的完整初始化。**
而 `ubiupdatevol` 刚改写过卷表，热复位时 UBI fastmap 状态可能不一致，
BL2 挂载失败就没有任何输出。

**正确做法是断电冷启动**，让 BL2 从头扫描 UBI。

这一点在刷机流程里同样重要：第 ① 步 `flash-bl2` 之后到第 ⑤ 步 `flash-uboot`
成功之前，**不要断电**；但写完所有卷之后，**要断电而不是 reboot**。

---

## 9. 对照表：厂商格式 vs 驱动格式

| 项 | 厂商 `fiberhomebdbob` | 驱动 `APONCAL` |
| --- | --- | --- |
| 魔数 | `"fiberhomebdbob"` (14 B) | `"APONCAL\0"` (8 B) |
| 版本 | 文本 `"202404291559VB"` | `u16` = 1 |
| 头长 | 无明确定义 | `u16` @0x0a = 0x80 |
| 型号位置 | 偏移 `0x95`，文本 `"ux3363"` | 由 I2C 硬件读取 |
| 载荷长度 | 隐式 | `u32` @0x14，需 `<= cell-0x80` |
| 谁认识它 | FiberHome 自己的内核 | `airoha-paged-bosa` |

**这两种格式互不兼容。** 厂商的校准块是给厂商固件用的，
而开源驱动需要 Airoha 定义的结构。

参考其他板子的 DTS 也能看出线索 —— `an7581-fiberhome-ubi-parts.dtsi` 里写着：

```dts
/* FiberHome BDBOB retains its 2048-byte binary format. */
pon_calibration: calibration@0 {
	reg = <0x0000 0x0800>;
};
```

注释说"保留其 2048 字节二进制格式"，但也只是把它原样暴露出来，
**能否被驱动接受取决于驱动，而不是这段注释。**

---

## 10. 载荷的语义：它是光模块 EEPROM 的页镜像

最初以为载荷是"校准系数表"，把它留给"需要参考设备才能解决"。
继续反汇编 `ux3363_apply` 后完全否定了这个判断 —— **载荷结构是明确的**。

### 10.1 函数入口就钉死了长度

```asm
00000000000010ac <ux3363_apply>:
    10ac:  stp  x29, x30, [sp, #-64]!
    10b8:  cmp  x2, #0x780              ; 第三个参数（载荷长度）必须精确等于 1920
    10bc:  b.ne 12e4 <ux3363_apply+0x238>
    ...
    12e4:  mov  w19, #0xffffffea         ; -EINVAL
```

**`payload_len` 不是 1920 就直接返回 `-EINVAL`。**
所以"24 字节裸头 + payload_len = 0"虽然能让 `bosa_probe` 通过
（状态显示 `calibration: ready`），但 `ux3363_apply` 会在第一条比较上失败，
PON 依然起不来。

### 10.2 载荷被切片写入模块的 I2C 页

```asm
    /* 页 0x80：逐字节写寄存器，从 0 到 0xB7 */
    1268:  loop: ldrb  w2, [x21, w2, sxtw]   ; payload[index]
    12ac:  mov   w1, w3
    12b4:  cmp   w3, #0xb7
    12b8:  b.ne  loop
    12bc:  orr   w2, w2, #0x1                 ; 寄存器 0xB7 额外置 bit0
    12c4:  bl    airoha_paged_bosa_write

    /* 页镜像搬运 */
    1224:  add  x3, x21, #0x100   len 0x7b (123)
    114c:  add  x3, x21, #0x280   len 0x69 (105)   page 0x81
    1170:  add  x3, x21, #0x300   len 0x69 (105)   page 0x82
    1194:  add  x3, x21, #0x400   len 0x69 (105)   page 0x83
    11b8:  add  x3, x21, #0x380   len 0x54 ( 84)   page 0x84
    11dc:  add  x3, x21, #0x3d6   len 0x08 (  8)   page 0x84
    1200:  add  x3, x21, #0x3e0   len 0x0b ( 11)   page 0x84
```

### 10.3 完整切片表

| 载荷偏移 | 长度 | 目标 | 说明 |
| --- | --- | --- | --- |
| `0x000..0x0B7` | 184 | page 0x80 reg 0x00–0xB7 | 逐字节寄存器配置 |
| `0x100..0x17A` | 123 | — | 页镜像块 |
| `0x280..0x2E8` | 105 | page 0x81 | 页镜像 |
| `0x300..0x368` | 105 | page 0x82 | 页镜像 |
| `0x380..0x3D3` | 84 | page 0x84 | 页镜像 |
| `0x3D6..0x3DD` | 8 | page 0x84 | 页镜像 |
| `0x3E0..0x3EA` | 11 | page 0x84 | 页镜像 |
| `0x400..0x468` | 105 | page 0x83 | 页镜像 |

**载荷是光模块 A2h EEPROM 的完整页镜像，1920 字节，不是抽象的"系数"。**

### 10.4 收尾动作也解出来了

```asm
    12ec:  read  reg 0x6e                    ; 页 0x84 的 0x6e
    1314:  orr   w2, w2, #0x40               ; 置 bit6
    1318:  bl    airoha_paged_bosa_write
    1330:  usleep 10-11 ms
    1340:  and   w2, w2, #0xffffffbf         ; 清 bit6
    1344:  bl    airoha_paged_bosa_write
```

这是给模块一个"重新加载配置"的脉冲，说明写入的页在模块侧会被缓存，
需要这个动作才生效。

### 10.5 为什么厂商格式不能简单转换

```
fiberhomebdbob   592 字节有效数据，厂商内核自己的系数表
APONCAL         1920 字节，光模块 EEPROM 的页镜像

前者是"算出来的补偿值"，后者是"要烧进模块的寄存器内容"。
不是同一层的东西，没有逐字节的映射关系。
```

### 10.6 一条实际的取得路径

因为载荷是模块 EEPROM 的页镜像，**它可能本来就在模块里**。

用厂商固件运行时，厂商内核驱动大概率已经把页面写进去了。如果那些页还在，
就可以直接从模块读出来，拼成 APONCAL 载荷：

```sh
# 需要设备能启动，且模块已经处于被厂商驱动初始化过的状态
# 1. select page 0x80，逐字节读 0x00..0xB7
# 2. select page 0x81..0x84，按上表的长度读
# 3. 按上表的偏移拼成 1920 字节
# 4. 前面加 0x80 字节 APONCAL 头
# 5. ubiupdatevol 写入
```

**这条路需要设备先恢复。** 而当前设备静默，那是第一优先级。

### 10.7 诚实记录未完成的部分

即使载荷结构完全清楚了，还缺一样东西：**这 1920 字节的具体内容**。

- 如果模块 EEPROM 里还保留着厂商写入的页，可以读出来用（§10.6）
- 如果模块被擦除过或从未写过，就只能从另一台 calibrated 设备取参考

**这一步在当前条件下没有完成，不能假装完成。**
但和最初的判断相比，问题已经从"不知道载荷是什么"缩小到
"知道它是模块 EEPROM 镜像，缺具体的 1920 字节内容"。

---

## 11. 可复用的诊断顺序

遇到"驱动说某个数据块无效"时：

1. **确认数据被读到了** —— 打印卷/分区的原始内容（`hexdump -C /dev/ubiX_Y`）
2. **确认 phandle 链对** —— 对比 nvmem provider 的 `phandle` 和 consumer 的 `nvmem-cells`
3. **确认不是别的东西** —— 有的"型号"其实来自 I2C/SPI 硬件，不是数据块
4. **反汇编校验函数** —— `objdump -d` 加上 `awk '/<fn>:/,/^$/'` 逐条读比较指令
5. **还原每个比较的两个操作数** —— 魔数字节、长度边界、版本号
6. **用最小载荷验证** —— 只满足头部，载荷长度填 0，先让 probe 过
7. **找同类设备的参考** —— 其它板子的 DTS 往往写着"这个格式是什么"

这七步在本项目里把 `calibration invalid` 从"猜不出来"变成了"字节级明确"。
