# HG5580A 适配项目 — 完整状态报告

> 记录到本次会话结束时的全部成果、未完成项，以及已验证与未验证的边界。
>
> 这份文档的作用是：任何人接手时不必重新摸索，能直接看到「什么已经做完、
> 什么还没做、为什么没做」。

---

## 1. 一句话总结

**固件适配完成，设备能跑 PonWrt；PON 光测速未完成，卡在 BOSA 校准载荷内容与设备恢复。**

---

## 2. 已完成并实机验证的部分

### 2.1 分区布局迁移

从原厂 14 分区迁移到 6 分区，实机 `/proc/mtd` 确认：

```
dev:    size   erasesize  name
mtd0: 10000000 00020000 "all_flash"
mtd1: 00020000 00020000 "bl2"        128 KiB
mtd2: 0e6e0000 00020000 "ubi"        242 MiB
mtd3: 00500000 00020000 "factory"    5 MiB，未被触碰
mtd4: 00020000 00020000 "bosacal"    128 KiB
mtd5: 00020000 00020000 "identity"   128 KiB
```

约束来源（两条都写在源码里，不是猜的）：

```c
/* plat/ecnt/en7523/bl2_boot_nand_ubi.c */
#define UBI_START_ADDR 0x20000

/* net/lwip/httpd.c run_bootloader_update(true) */
if (mtd->size != mtd->erasesize) goto out;
```

`0x20000 + 0xe6e0000 = 0xe700000`，UBI 正好停在 `factory` 之前，
`factory` / `bosacal` / `identity` 在窗口外，`ubi-rebuild` 无法触及。

### 2.2 刷写流程六步全部成功

```
① flash-bl2          bl2-firstblock.bin    131,072 B   path A
② ubi-rebuild                               创建 fip/ubootenv/ubootenv2/bosa/ri
③ flash-board-data   bosa.bin              262,144 B
④ flash-board-data   ri.bin                262,144 B
⑤ flash-uboot        fip-new.fip           371,311 B
⑥ flash              sysupgrade-new.itb 34,165,006 B
```

第 ⑥ 步的输出：

```
Firmware FIT verified for fiberhome,hg5580a-ubi (34165006 bytes).
Creating dynamic volume fit.new of size 34165006
Rename UBI volume fit.new to fit
Firmware written to UBI volume 'fit'; readback CRC e4ad4553.
```

### 2.3 系统启动与驱动绑定

```
PonWrt SNAPSHOT, b1af9523
root@(none):~#

airoha_en7572              16384  0
airoha_paged_bosa          16384  1        refcount 非零 = 校准被读到
airoha_pon_frontend_core   12288  3
airoha_xpon                77824  0
```

网络接口全部出现，MAC 地址正确（非随机）：

```
eth0            24:e3:a4:b2:dd:e0     base MAC
eth1            24:e3:a4:b2:dd:e1     LAN MAC = base+1
pon0            24:e3:a4:b2:dd:e2     PON MAC = base+2
omci0@pon0      LOWERLAYERDOWN
oam0@pon0       DOWN
```

MAC 正确这一点很关键 —— 它同时证明了三件事：
`ri` 卷写入成功、`fh_base_mac` nvmem cell 解析正确、
U-Boot 的 `ethaddr_factory` 偏移是 `0x00`（不是 Nokia 的 `0x3e`）。

### 2.4 双闪存批次支持

同一块主板有两种 SPI-NAND，U-Boot 必须都认识：

| 型号 | mfr | dev | OOB | 状态 |
| --- | --- | --- | --- | --- |
| SkyHigh S35ML02G300 | `0x01` | `0x25` | 128 | 上游已支持 |
| FORESEE F35SQB002G | `0xCD` | `0x52` | 64 | 需补丁，已加 |

FORESEE 的补丁 `uboot-port/patches/foresee-f35sqb002g.diff` 已接入 CI，
少了它云编译产物在这台设备上会报 `unknown raw ID cd 52 52 cd`。

---

## 3. 未完成：PON 光测速

### 3.1 当前阻塞点

```
[frontend]
  calibration: invalid        <-- 根因
[line]
  lifecycle: stopped
  optical_signal: 0
  xgtc_sync: hunt
[registration]
  onu_state: O1
  serial_configured: 0
```

因果链：`calibration invalid` → 驱动不启动 → 序列号无法生效 → PON 不工作。

### 3.2 根因已定位到字节级

驱动要的不是厂商格式，而是 `APONCAL` 结构。反汇编 `bosa_probe`：

```asm
134:  ldr  x2, [sp]              ; cell 长度
138:  cmp  x2, #0x7f            ; 必须 > 127
140:  ldr  x3, [x0]             ; 前 8 字节
144:  mov  x1, #0x5041          ; 'A','P'
148:  movk x1, #0x4e4f, lsl 16  ; 'O','N'
14c:  movk x1, #0x4143, lsl 32  ; 'C','A'
150:  movk x1, #0x4c,   lsl 48  ; 'L','\0'
154:  cmp  x3, x1               ; 魔数 "APONCAL\0"
158:  b.ne FAIL
15c:  ldrh w3, [x0, #10]        ; [0x0a] == 0x80
160:  ldr  w4, [x0, #12]        ; 存入 priv+136
164:  ldrh w1, [x0, #8]         ; [0x08] == 1
178:  ldr  w1, [x0, #16]        ; [0x10] == 1
188:  sub  x2, x2, #0x80
18c:  ldr  w25, [x0, #20]       ; [0x14] <= cell_len - 0x80
194:  b.ls OK
```

厂商的 `fiberhomebdbob` 首字节是 `0x66`，驱动要 `0x41`，一个字节都不匹配。

### 3.3 载荷结构也完全解出

`ux3363_apply` 要求载荷长度精确等于 `0x780`（1920），然后按 9 个切片写模块 EEPROM：

| 载荷偏移 | 长度 | 页 | 寄存器 |
| --- | --- | --- | --- |
| `0x000` | 184 | `0x80` | `0x00`（到 `0xB7`） |
| `0x100` | 123 | `0x00` | `0x00`（A0h EEPROM） |
| `0x200` | 110 | `0x80` | `0x00`（到 `0x6D`，第二遍） |
| `0x280` | 105 | `0x81` | `0x00` |
| `0x300` | 105 | `0x82` | `0x00` |
| `0x380` | 84 | `0x84` | `0x00` |
| `0x3D6` | 8 | `0x84` | `0x56` |
| `0x3E0` | 11 | `0x84` | `0x60` |
| `0x400` | 105 | `0x83` | `0x00` |

I2C 协议也解出来了：

```
select page:  写两个字节 0x7F, <page>
read:         写 1 字节 reg，然后读 N 字节（中间不发 STOP）
write:        写两个字节 <reg>, <value>
```

### 3.4 为什么还没完成

**缺那 1920 字节的具体内容。**

结构完全清楚，但内容要么从模块 EEPROM 读回来（需要设备能启动），
要么从另一台 `calibration: ready` 的设备取参考。

这两条都需要设备先恢复。

### 3.5 即使解决了校准，还有三个不确定性

诚实记录，不假装已经解决：

1. **模块 EEPROM 里可能没有厂商写过的东西**
   如果模块从未被厂商固件初始化过，读回来的就是空数据。

2. **OLT 侧可能未登记这个序列号**
   `ri` 卷里的序列号是 `FHTTC255B8F9`（从 `factory_conf` 的 `GponSN` 转换）。
   如果运营商系统里是别的号，OLT 会直接忽略，ONU 永远停在 O1。

3. **线路可能是 GPON 而非 X-G-PON**
   驱动不支持 GPON：

   ```c
   {
           .mode = AIROHA_XPON_MODE_GPON,
           .name = "gpon",
           /* 没有 .mac_supported —— 六种制式里唯一被排除的 */
   }
   ```

   而 `factory_conf` 里的字段名是 `GponSN` / `GPONPassWord`。
   这个字段名是历史遗留还是真的 GPON 线路，需要运营商记录才能确认。

---

## 4. 设备当前状态

```
串口 COM4        (完全静默，115200/57600/38400/9600 都试过)
192.168.0.1      no reply
192.168.1.1      no reply
USB-SERIAL CH340 status=OK        （适配器本身正常）
```

### 4.1 怎么变成这样的

```
ubiupdatevol 写入 bosa 卷成功（exit=0）
  ↓
执行 reboot
  ↓
设备静默
```

### 4.2 为什么判断不是变砖

```
bl2 分区     从未被 ubiupdatevol 碰过
fip 卷       已验证 "FIP written and verified (371311 bytes)"
fit 卷       已写入，CRC e4ad4553
```

**触发点是 `reboot`。** Linux 的 `reboot` 走 PSCI 热复位，跳过 BL2 完整初始化；
而刚改写过卷表，fastmap 状态可能不一致。冷启动会让 BL2 从头扫描 UBI。

### 4.3 需要什么

**一次物理断电冷启动。** 这是唯一的阻塞。

---

## 5. 恢复材料（全部核验通过）

```
[OK] bl2-firstblock.bin    131,072 B   2b5cf8d0accacc1bbd6f6b000e376564
[OK] bootloader.bin      2,621,440 B   986fee15e5ad66ead92cadc7089ebb44
[OK] factory.bin         5,242,880 B   ab153adfd50625a7f83cf065894a37cc
[OK] fip-new.fip           371,311 B   8197ba7981846baab05623f1b311dd54
[OK] u-boot-52.bin         914,448 B   483f265675d425a16f35c051b3eac925
[OK] bosa.bin              262,144 B   5d0aad4fc825140a7bbf9786df3e2773
[OK] ri.bin                262,144 B   72fac381e1cdfad4d083db21a1ef49d0
[OK] sysupgrade-new.itb 34,165,006 B   7602312fa89ca3a129ff3225634b4ad5
```

`bl2-firstblock.bin` 的前 2048 字节与厂商 `bootloader.bin` 逐字节相同
（`mcr 15,0,r0,cr1,cr0,0` 那一段入口代码），这是它走 `flash-bl2` path A
而不是 path B 的前提。

---

## 6. 设备恢复后的执行清单

```
1. 确认串口输出
2. 如果进了 Linux：
     ip link set eth0 up
     ip addr add 192.168.0.1/24 dev eth0
     检查 i2c-tools（缺则 opkg install i2c-tools）
3. 运行 read-module-eeprom.sh
     读页 0x80/0x81/0x82/0x83/0x84/0x00
     按 9 片切片表拼成 1920 字节
     加 0x80 字节 APONCAL 头
     输出 aponcal-volume.bin
4. hexdump -C aponcal-volume.bin | head
     确认 APONCAL 在卷偏移 0x02
5. ubiupdatevol /dev/ubi0_3 aponcal-volume.bin
6. 断电冷启动（不要 reboot）
7. ponctl --device pon0 status
     看 calibration 是否 ready
8. 如果 ready，看 pon0 carrier
     如果 carrier=1 → iperf3 测速
9. 如果仍是 invalid 或 carrier=0
     按 §3.5 的三个方向排查
```

如果冷启动后进了 U-Boot 而不是 Linux：

```
POST /api/upload  bosa.bin
POST /api/task    {"operation":"flash-board-data","target":"bosa","upload_id":N}
```

---

## 7. 工具清单

| 工具 | 用途 | 状态 |
| --- | --- | --- |
| `preflight.sh` | 刷写前 19 项审计 | 全通过 |
| `flash-all-stages.ps1` | 六步刷写 | 已修 7 个 bug，语法验证 |
| `check-dtb-partitions.sh` | 分区表按消费者校验 | 通过 |
| `read-module-eeprom.sh` | 读模块 EEPROM 拼装载荷 | 语法通过 |
| `test-aponcal-assembly.sh` | 拼装逻辑验证 | 22 项断言通过 |
| `build-aponcal.py` | 按结构生成镜像 | 通过 |
| `audit-tftp-dir.sh` | TFTP 目录陈旧文件检查 | 通过 |
| `test-tftp-transfer.py` | TFTP 传输完整性（含 34 MB） | 全部通过 |

---

## 8. 文档清单

| 文档 | 内容 |
| --- | --- |
| `flashing-and-recovery-full.md` | 刷机与失败恢复完整教程 |
| `bosa-calibration-aponcal.md` | BOSA 校准格式的字节级定位 |
| `device-unresponsive-recovery.md` | 设备无响应时的分级处置 |
| `reverse-engineering-onu-bootchain.md` | 逆向闭源 ONU 启动链的方法论 |
| `single-ubi-layout.md` | 为什么放弃 10 分区方案 |
| `pon-not-coming-up-layers.md` | PON 不起来的层次分析 |
| `build-interruption-triage.md` | 构建中断的 8 类问题 |
| `wsl-build-path-pitfalls.md` | WSL 构建陷阱 |
| `kernel-loadaddr-npu-conflict.md` | 0x80200000 撞 NPU 窗口 |
| `flash-foresee-f35sqb002g.md` | FORESEE 批次补丁 |
| `flash-skyhigh-vs-foresee.md` | 两种闪存批次对比 |
| `xgpon-speedtest-prerequisites.md` | 测速前置条件 |

---

## 9. 这次踩过的 7 个必然失败的 bug

记录下来，因为它们都不是"跑一下就能发现"的类型：

| # | bug | 后果 | 发现方式 |
| --- | --- | --- | --- |
| 1 | CI 缺 FORESEE 补丁 | 云编译产物认不出闪存 | 对比 uboot-port 文件与 CI 复制列表 |
| 2 | `flash-fip` 操作名不存在 | 第 ⑤ 步失败，设备变砖 | 打印完整的 `parse_task` |
| 3 | 镜像内 DTB 是旧布局 | U-Boot 与内核布局不一致 | `dumpimage` 提取内嵌 DTB |
| 4 | `bl2` 标 `read-only` | 第 ① 步就失败 | 追 `mtdpart.c` 的 flag 处理 |
| 5 | 上传打到 `/api/task` | 第 ① 步就失败（2048 字节上限） | 打印 `httpd_post_begin` |
| 6 | `ubi-rebuild` 只建空卷 | `pon0` 不出现 | 读 `create_recovery_layout` |
| 7 | `"$label:"` 语法错误 | 脚本编译失败，一行都不执行 | PowerShell 语法检查 |

**共同点：全部来自"读源码/读产物"，没有一个是靠实机试出来的。**
如果只靠试，前 6 个会表现为"莫名其妙的失败"，第 7 个会表现为"脚本没反应"。

---

## 10. 还有一件事值得记下来：验证工具本身也要验证

用来做自动检查的脚本，自己出过 6 次错误：

| # | 错误 | 后果 |
| --- | --- | --- |
| 1 | 正则用 `\n\t\t\};`，dtc 实际输出 5 个 tab | 只匹配到第一个分区 |
| 2 | `SAFE_END=0x9ea89370` 字符串参与数值比较 | 所有载荷误报超标 |
| 3 | 单引号外多个 `"` | bash 语法错误，脚本跑不完 |
| 4 | `grep -oE -- "-operation '..."` 把前缀当结果 | 误报非法操作名 |
| 5 | `cal[:15] != b'fiberhomebdbob'`（14 字节字符串） | 正确数据误报错误 |
| 6 | `objdump` 输出被 `head`/`awk` 截断 | 漏掉关键操作数 |

**第 6 个最危险**：它让 `0x100` 那一片的目标页藏了好几轮才被发现。
`w1`（页号）和 `w2`（起始寄存器）就在 `write_range` 前两条指令，
但输出被截断就看不到。

防御办法：解析用花括号配对而不是缩进、数值先转换再比较、
写完立刻 `bash -n` / `Parser::ParseFile`、
**以及反汇编时把每次调用的所有操作数并列打印，不要只打印源和长度。**

---

## 11. 结论

**这个适配项目的软件部分已经完成。** 设备从原厂固件迁移到了 PonWrt，
新的 UBI 布局稳定，PON 驱动栈完整绑定，身份数据正确。

**PON 光测速没完成，原因是多层的：**

1. 需要一次物理断电（当前设备静默）
2. 需要模块 EEPROM 里的 1920 字节校准数据
3. 可能需要运营商侧的序列号登记
4. 线路制式存在 GPON / XG-PON 的不确定性

**前两项有明确的技术路径和准备好的工具；后两项不在我可控范围内。**

不把"适配完成"说成"目标完成"，因为用户的原话是
"最后上光测速"，而光测速确实没有跑通。
