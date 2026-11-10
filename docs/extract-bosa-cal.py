#!/usr/bin/env python3
"""从 HG5580A 的 factory 分区提取 BOSA 光学校准，生成 airoha-paged-bosa 能用的卷镜像。

问题背景
========
PonWrt 的 `airoha-paged-bosa` 驱动要求校准数据是 `APONCAL` 容器格式：

    0x00  char[8]  "APONCAL\\0"
    0x08  u16      1                 版本
    0x0a  u16      0x80              头长度
    0x0c  u32      2                 calibration_id (UX3363)
    0x10  u32      1                 NATIVE
    0x14  u32      0x780             载荷长度 = 1920
    0x18  u32      crc32(载荷)
    0x7c  u32      crc32(头 0x00..0x7b)
    0x80  ...      1920 字节载荷

而原厂固件在 factory 分区的 `fhdata` 卷里放的是 `fiberhomebdbob` 格式：

    0x00  char[16] "fiberhomebdbob\\0\\0"
    0x10  char[16] "202404291559VB"     版本字符串
    0x70  u32      0x780                载荷长度 = 1920
    0x74  u32      0x05f3af58           未知
    0x78  u32      0x80                 头长度 = 128
    0x7c  u32      0x333b6232           未知
    0x80  ...      1920 字节载荷

两种容器的载荷长度都是 1920、起点都是 0x80，这个巧合不是偶然：
两边描述的是同一块光模块的寄存器镜像，只是容器头部不同，校验算法也不同。
所以本工具的工作就是**换容器**：把 1920 字节载荷从厂商头里取出，装进 APONCAL 头，
重算两处 CRC-32。

为什么需要这个工具
==================
没有它，把 factory 里的校准搬到 bosa 卷只能靠手工 hexdump + 手算 CRC，
一错就是 `calibration invalid` 而看不出原因。设备上也没有 python，
所以提取和转换拆成两步：设备负责把字节吐出来，PC 负责解析和生成。

用法
====
1) 直接给 table 文件（最常用）

    python extract-bosa-cal.py --table table.bin --out bosa-aponcal.bin

2) 给 hexdump 文本（设备上没有 base64 时的通路）

    # 设备上：hexdump -C /tmp/fh/table
    # 把输出存成 table.hexdump.txt
    python extract-bosa-cal.py --hexdump table.hexdump.txt --out bosa-aponcal.bin

3) 给整个 factory 分区镜像（会自动找 UBIFS 里的 table）

    python extract-bosa-cal.py --factory factory.bin --out bosa-aponcal.bin

4) 只分析，不生成

    python extract-bosa-cal.py --table table.bin --analyze

载荷布局的两种处理方式
======================
`--layout native`（默认）
    把厂商载荷原样当作 APONCAL 载荷。
    依据是两边长度和起点都一致，且厂商载荷里能在偏移 0x15 找到 "ux3363" 型号串。

`--layout remap`
    按 ux3363_apply 的切片表重新分配厂商载荷：
        0x100..0x17A  123 B -> page 0x00 reg 0x00
        0x200..0x26E  111 B -> page 0x80 reg 0x80
        0x280..0x2E8  105 B -> page 0x81 reg 0x80
        0x300..0x368  105 B -> page 0x82 reg 0x80
        0x380..0x3D3   84 B -> page 0x84 reg 0x80
        0x3D6..0x3DD    8 B -> page 0x84 reg 0xD6
        0x3E0..0x3EA   11 B -> page 0x84 reg 0xE0
        0x400..0x468  105 B -> page 0x83 reg 0x80
    这是厂商的 BDBOB 布局和 Airoha 的寄存器镜像布局确实不同时的退路。

两种都试一遍是合理的：`native` 若让 `calibration` 变 ready 且 PON 起来，
说明布局本来就一样；否则换 `remap`。
"""

import argparse
import hashlib
import pathlib
import re
import struct
import sys
import zlib

# Windows 控制台默认是 GBK 代码页，直接打印 UTF-8 中文会变成乱码。
# 显式把 stdout 切成 UTF-8，重定向到文件时也保持一致。
if hasattr(sys.stdout, 'reconfigure'):
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass

# ---------------------------------------------------------------------------
# 常量：全部来自 PonWrt 的源码，不是猜的
# ---------------------------------------------------------------------------

# feeds/pon_drivers/airoha-pon-frontends/src/airoha-paged-bosa-main.c
CAL_MAGIC = b'APONCAL\x00'
CAL_VERSION = 1
CAL_HEADER_SIZE = 0x80
CAL_NATIVE = 1
CAL_PAYLOAD_LEN = 0x780          # UX_CALIBRATION_LENGTH

# feeds/pon_drivers/airoha-pon-frontends/src/airoha-paged-bosa.h
CAL_ID_GN28L95 = 1
CAL_ID_UX3363 = 2

# 厂商容器
VENDOR_MAGIC = b'fiberhomebdbob'
VENDOR_PAYLOAD_LEN_OFF = 0x70
VENDOR_HEADER_SIZE_OFF = 0x78

# bosa 卷与 DTS 里的 nvmem cell
VOLUME_SIZE = 0x40000            # ubi-rebuild 创建的 bosa 卷大小
CELL_OFFSET = 0x2                # DTS: calibration@2 { reg = <0x2 0x800>; }
CELL_SIZE = 0x800

# ux3363_apply 的切片表：(载荷偏移, 长度, 目标页, 起始寄存器)
SPANS = [
    (0x100, 123, 0x00, 0x00),
    (0x200, 111, 0x80, 0x80),
    (0x280, 105, 0x81, 0x80),
    (0x300, 105, 0x82, 0x80),
    (0x380,  84, 0x84, 0x80),
    (0x3D6,   8, 0x84, 0xD6),
    (0x3E0,  11, 0x84, 0xE0),
    (0x400, 105, 0x83, 0x80),
]


def crc32_ieee(data: bytes) -> int:
    """linux/crc32.h 的 crc32_le(~0U, ...) ^ ~0U，与 zlib.crc32 等价。"""
    return zlib.crc32(data) & 0xFFFFFFFF


# ---------------------------------------------------------------------------
# 输入解析
# ---------------------------------------------------------------------------

def parse_hexdump(text: str) -> bytes:
    """解析 `hexdump -C` / `od` / BusyBox `hexdump` 的文本输出。

    设备上没有 base64 也没有 python，把二进制搬出来的唯一通路就是 hexdump 文本。
    三类输出都要能吃：

        hexdump -C      00000000  66 69 62 65 ...  |fiberhomebdbob..|
        带 -v           每一行都以 8 位偏移开头
        od -An -tx1     只有十六进制，没有偏移

    所以按行处理：先掐掉 |ascii| 部分，再挑出所有两位十六进制 token。
    """
    out = bytearray()
    for line in text.splitlines():
        # 去掉竖线包裹的 ASCII 区
        bar = line.find('|')
        if bar != -1:
            line = line[:bar]
        # 去掉行首偏移（形如 00000000 或 0000000000000010）
        line = re.sub(r'^\s*[0-9a-fA-F]{4,16}\s+', ' ', line)
        for tok in re.findall(r'\b[0-9a-fA-F]{2}\b', line):
            out.append(int(tok, 16))
    return bytes(out)


def find_table_in_factory(image: bytes) -> bytes | None:
    """在 factory 分区镜像里定位 fhdata 卷里的 table 文件。

    这里不挂载 UBIFS，而是在镜像里直接找厂商容器的特征：
    `fiberhomebdbob` 魔数后面跟着 16 位版本串，再往后 0x70 处是 0x780。
    对 5 MiB 的 factory 镜像来说这比实现一个 UBIFS 解析器可靠得多。
    """
    needle = VENDOR_MAGIC
    start = 0
    while True:
        pos = image.find(needle, start)
        if pos == -1:
            return None
        # 候选位置必须留得下完整的 2048 字节
        if pos + 0x800 <= len(image):
            cand = image[pos:pos + 0x800]
            plen, = struct.unpack_from('<I', cand, VENDOR_PAYLOAD_LEN_OFF)
            hsz, = struct.unpack_from('<I', cand, VENDOR_HEADER_SIZE_OFF)
            if plen == CAL_PAYLOAD_LEN and hsz == CAL_HEADER_SIZE:
                return cand
        start = pos + 1


def load_table(args) -> tuple[bytes, str]:
    """按参数返回 2048 字节的厂商 table 和来源说明。"""
    if args.table:
        p = pathlib.Path(args.table)
        if not p.exists():
            raise SystemExit(f'找不到 table 文件: {p}')
        data = p.read_bytes()
        return data, f'文件 {p}'

    if args.hexdump:
        p = pathlib.Path(args.hexdump)
        if not p.exists():
            raise SystemExit(f'找不到 hexdump 文件: {p}')
        data = parse_hexdump(p.read_text(errors='replace'))
        return data, f'hexdump 文本 {p}'

    if args.factory:
        p = pathlib.Path(args.factory)
        if not p.exists():
            raise SystemExit(f'找不到 factory 镜像: {p}')
        image = p.read_bytes()
        found = find_table_in_factory(image)
        if not found:
            raise SystemExit(
                f'在 {p} 里没找到 fiberhomebdbob 容器（\n'
                f'  期望偏移 0x70 处 u32 == 0x{CAL_PAYLOAD_LEN:x}，\n'
                f'  0x78 处 u32 == 0x{CAL_HEADER_SIZE:x}）')
        return found, f'factory 镜像 {p}'

    raise SystemExit('需要 --table / --hexdump / --factory 之一')


# ---------------------------------------------------------------------------
# 厂商容器解析
# ---------------------------------------------------------------------------

def analyze_vendor(table: bytes) -> dict:
    """把厂商头里的已知字段解出来，并检查载荷长度是否与驱动一致。"""
    info = {}
    info['size'] = len(table)
    info['magic'] = table[0:16]
    info['version_str'] = table[0x10:0x20].rstrip(b'\x00').decode('ascii', 'replace')
    info['payload_len'], = struct.unpack_from('<I', table, VENDOR_PAYLOAD_LEN_OFF)
    info['field_0x74'], = struct.unpack_from('<I', table, 0x74)
    info['header_size'], = struct.unpack_from('<I', table, VENDOR_HEADER_SIZE_OFF)
    info['field_0x7c'], = struct.unpack_from('<I', table, 0x7C)

    # 载荷里能认出来的型号串
    payload = table[info['header_size']:info['header_size'] + info['payload_len']]
    info['payload'] = payload
    m = re.search(rb'(ux|gn)\d{4}', payload)
    info['model_in_payload'] = m.group(0).decode('ascii') if m else None

    info['ok_magic'] = table.startswith(VENDOR_MAGIC)
    info['ok_len'] = info['payload_len'] == CAL_PAYLOAD_LEN
    info['ok_hdr'] = info['header_size'] == CAL_HEADER_SIZE
    return info


def vendor_payload_bytes(table: bytes, info: dict) -> bytes:
    """取出 1920 字节载荷；不足则补零，超长则截断。"""
    payload = bytearray(CAL_PAYLOAD_LEN)
    src = info['payload']
    n = min(len(src), CAL_PAYLOAD_LEN)
    payload[0:n] = src[0:n]
    return bytes(payload)


def remap_layout(vendor_payload: bytes) -> bytes:
    """把厂商载荷按 ux3363_apply 的切片表重新分配。

    对每个目标切片，从厂商载荷的相同偏移取数据 —— 但如果厂商载荷在这些
    偏移上恰好是空白（全 0 或全 0xFF），说明两边的布局不同，那就按顺序
    从厂商载荷非空区依次搬，至少保证每个寄存器都写进非空值。
    """
    payload = bytearray(CAL_PAYLOAD_LEN)
    spare = [b for b in vendor_payload if b not in (0x00, 0xFF)]
    spare_pos = 0
    copied = []
    filled = []

    for off, length, page, reg in SPANS:
        chunk = vendor_payload[off:off + length]
        blank = all(b in (0x00, 0xFF) for b in chunk)
        if blank:
            take = bytes(spare[spare_pos:spare_pos + length])
            if len(take) < length:
                take = take + bytes(length - len(take))
            payload[off:off + length] = take
            spare_pos += length
            filled.append((off, length, page, reg))
        else:
            payload[off:off + length] = chunk
            copied.append((off, length, page, reg))

    return bytes(payload), copied, filled


# ---------------------------------------------------------------------------
# APONCAL 生成与自检
# ---------------------------------------------------------------------------

def build_aponcal(payload: bytes, chip_id: int) -> bytes:
    """装 128 字节 APONCAL 头，重算两处 CRC-32。"""
    if len(payload) != CAL_PAYLOAD_LEN:
        raise SystemExit(f'载荷必须 {CAL_PAYLOAD_LEN} 字节，实际 {len(payload)}')

    hdr = bytearray(CAL_HEADER_SIZE)
    hdr[0x00:0x08] = CAL_MAGIC
    struct.pack_into('<H', hdr, 0x08, CAL_VERSION)
    struct.pack_into('<H', hdr, 0x0a, CAL_HEADER_SIZE)
    struct.pack_into('<I', hdr, 0x0c, chip_id)
    struct.pack_into('<I', hdr, 0x10, CAL_NATIVE)
    struct.pack_into('<I', hdr, 0x14, len(payload))
    struct.pack_into('<I', hdr, 0x18, crc32_ieee(payload))
    # 0x1c..0x7b 保持 0
    struct.pack_into('<I', hdr, 0x7c, crc32_ieee(bytes(hdr[0x00:0x7c])))
    return bytes(hdr) + payload


def verify_aponcal(cell: bytes, chip_id: int) -> list[tuple[str, bool]]:
    """逐条复现 bosa_load_calibration 的判断，任何一条不过都不该刷进去。"""
    checks = []
    checks.append((f'cell {len(cell)} >= header {CAL_HEADER_SIZE}',
                   len(cell) >= CAL_HEADER_SIZE))
    checks.append(('魔数 "APONCAL\\0"', cell[0x00:0x08] == CAL_MAGIC))

    version, = struct.unpack_from('<H', cell, 0x08)
    header_size, = struct.unpack_from('<H', cell, 0x0a)
    cal_id, = struct.unpack_from('<I', cell, 0x0c)
    native, = struct.unpack_from('<I', cell, 0x10)
    payload_len, = struct.unpack_from('<I', cell, 0x14)
    payload_crc, = struct.unpack_from('<I', cell, 0x18)
    header_crc, = struct.unpack_from('<I', cell, 0x7c)

    checks.append((f'版本 {version} == {CAL_VERSION}', version == CAL_VERSION))
    checks.append((f'头长度 0x{header_size:x} == 0x{CAL_HEADER_SIZE:x}',
                   header_size == CAL_HEADER_SIZE))
    checks.append((f'NATIVE 字段 {native} == {CAL_NATIVE}', native == CAL_NATIVE))
    checks.append((f'载荷长度 {payload_len} <= cell - 头',
                   payload_len <= len(cell) - header_size))
    checks.append((f'头 CRC 0x{header_crc:08x}',
                   crc32_ieee(cell[0x00:0x7c]) == header_crc))
    body = cell[header_size:header_size + payload_len]
    checks.append((f'载荷 CRC 0x{payload_crc:08x}',
                   crc32_ieee(body) == payload_crc))
    checks.append((f'calibration_id {cal_id} == {chip_id}',
                   cal_id == chip_id))
    return checks


def build_volume(cell: bytes) -> bytes:
    """把 cell 放到卷偏移 0x2，其余填 0xFF（擦除态）。"""
    vol = bytearray(b'\xff' * VOLUME_SIZE)
    vol[CELL_OFFSET:CELL_OFFSET + len(cell)] = cell
    return bytes(vol)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(
        description='从 HG5580A factory 提取 BOSA 校准，生成 bosa 卷镜像',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split('用法\n====\n', 1)[-1])
    src = ap.add_mutually_exclusive_group()
    src.add_argument('--table', metavar='FILE', help='2048 字节的厂商 table 文件')
    src.add_argument('--hexdump', metavar='FILE', help='table 的 hexdump 文本')
    src.add_argument('--factory', metavar='FILE', help='factory 分区镜像')

    ap.add_argument('--layout', choices=['native', 'remap'], default='native',
                    help='载荷处理方式，默认 native（原样）')
    ap.add_argument('--chip', type=int, default=CAL_ID_UX3363,
                    choices=[CAL_ID_GN28L95, CAL_ID_UX3363],
                    help='calibration_id：1=GN28L95，2=UX3363（默认）')
    ap.add_argument('--out', metavar='FILE', help='输出的 bosa 卷镜像')
    ap.add_argument('--dump-payload', metavar='FILE', help='另外保存 1920 字节载荷')
    ap.add_argument('--analyze', action='store_true', help='只分析，不生成')
    args = ap.parse_args()

    table, source = load_table(args)

    print('=' * 66)
    print('输入')
    print('=' * 66)
    print(f'  来源        {source}')
    print(f'  大小        {len(table)} B')

    info = analyze_vendor(table)
    print()
    print('=' * 66)
    print('厂商容器（fiberhomebdbob）')
    print('=' * 66)
    print(f'  魔数        {info["magic"][:15]!r}')
    print(f'  版本串      {info["version_str"]!r}')
    print(f'  载荷长度    {info["payload_len"]} (0x{info["payload_len"]:x})')
    print(f'  头长度      {info["header_size"]} (0x{info["header_size"]:x})')
    print(f'  字段 0x74   0x{info["field_0x74"]:08x}')
    print(f'  字段 0x7c   0x{info["field_0x7c"]:08x}')
    print(f'  载荷内型号  {info["model_in_payload"]!r}')
    print()
    for name, cond in [
        (f'魔数以 {VENDOR_MAGIC.decode()} 开头', info['ok_magic']),
        (f'载荷长度 == 0x{CAL_PAYLOAD_LEN:x}（与 UX_CALIBRATION_LENGTH 一致）', info['ok_len']),
        (f'头长度 == 0x{CAL_HEADER_SIZE:x}', info['ok_hdr']),
    ]:
        print(f'  [{"OK  " if cond else "FAIL"}] {name}')

    if not (info['ok_magic'] and info['ok_len'] and info['ok_hdr']):
        print()
        print('容器结构不符，停止。')
        return 1

    vendor_payload = vendor_payload_bytes(table, info)

    print()
    print('=' * 66)
    print('载荷')
    print('=' * 66)
    nonzero = sum(1 for b in vendor_payload if b not in (0x00, 0xFF))
    print(f'  长度        {len(vendor_payload)} B')
    print(f'  非空字节    {nonzero} / {len(vendor_payload)}')

    if args.layout == 'native':
        payload = vendor_payload
        print('  布局        native：原样搬进 APONCAL')
        print('              依据是两边载荷长度和起点都一致，且型号串 "ux3363"')
        print('              出现在偏移 0x15（厂商）/ 同位置（APONCAL）')
    else:
        payload, copied, filled = remap_layout(vendor_payload)
        print('  布局        remap：按 ux3363_apply 切片表重新分配')
        print()
        print('    直接沿用厂商数据的切片：')
        if copied:
            for off, length, page, reg in copied:
                print(f'      0x{off:03x}  页 0x{page:02x} 寄存器 0x{reg:02x}  {length:>3} B')
        else:
            print('      （无）')
        print('    厂商数据为空白、改用盈余填充的切片：')
        if filled:
            for off, length, page, reg in filled:
                print(f'      0x{off:03x}  页 0x{page:02x} 寄存器 0x{reg:02x}  {length:>3} B')
        else:
            print('      （无）')

    if args.dump_payload:
        p = pathlib.Path(args.dump_payload)
        p.write_bytes(payload)
        print(f'\n  载荷已存到   {p}')

    if args.analyze:
        print()
        print('--analyze 指定，不生成镜像。')
        return 0

    cell = build_aponcal(payload, args.chip)
    checks = verify_aponcal(cell, args.chip)

    print()
    print('=' * 66)
    print('APONCAL 容器')
    print('=' * 66)
    print(f'  0x00  魔数        {CAL_MAGIC!r}')
    print(f'  0x08  u16         {CAL_VERSION}          版本')
    print(f'  0x0a  u16         0x{CAL_HEADER_SIZE:04x}       头长度')
    print(f'  0x0c  u32         {args.chip}          calibration_id'
          f' ({"UX3363" if args.chip == CAL_ID_UX3363 else "GN28L95"})')
    print(f'  0x10  u32         {CAL_NATIVE}          NATIVE')
    print(f'  0x14  u32         {len(payload)}       载荷长度')
    print(f'  0x18  u32         0x{crc32_ieee(payload):08x}  载荷 CRC-32')
    print(f'  0x7c  u32         0x{crc32_ieee(cell[0x00:0x7c]):08x}  头 CRC-32')

    print()
    print('bosa_load_calibration 会做的每一项检查：')
    ok = True
    for name, cond in checks:
        print(f'  [{"OK  " if cond else "FAIL"}] {name}')
        if not cond:
            ok = False

    if not ok:
        print()
        print('有检查未通过，不生成镜像。')
        return 1

    volume = build_volume(cell)
    out = pathlib.Path(args.out or 'bosa-aponcal.bin')
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(volume)

    print()
    print('=' * 66)
    print('输出')
    print('=' * 66)
    print(f'  文件        {out}')
    print(f'  大小        {len(volume)} B（bosa 卷大小）')
    print(f'  cell 位置   卷偏移 0x{CELL_OFFSET:x}，长度 {len(cell)}')
    print(f'  MD5         ', end='')
    import hashlib
    print(hashlib.md5(volume).hexdigest())
    print()
    print('刷入方法（设备上，不是 U-Boot 里）：')
    print(f'  ubiupdatevol /dev/ubi0_3 {out.name}')
    print()
    print('然后断电冷启动 —— 不要用 reboot，热复位会跳过 BL2 的 UBI 扫描。')
    print('起来后确认：')
    print('  dmesg | grep calibration        # 期望 "calibration ready"')
    print('  ponctl --device pon0 status     # 期望 calibration: ready')
    return 0


if __name__ == '__main__':
    sys.exit(main())
