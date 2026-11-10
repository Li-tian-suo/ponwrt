#!/usr/bin/env python3
"""Build a valid APONCAL calibration container for airoha-paged-bosa.

Source of truth
---------------
feeds/pon_drivers/airoha-pon-frontends/src/airoha-paged-bosa-main.c, function
bosa_load_calibration.  Everything here comes from that function plus the header:

    #define AIROHA_BOSA_CAL_MAGIC       "APONCAL\\0"
    #define AIROHA_BOSA_CAL_VERSION     1
    #define AIROHA_BOSA_CAL_HEADER_SIZE 0x80
    #define AIROHA_BOSA_CAL_NATIVE      1

    enum airoha_bosa_calibration_id {
            AIROHA_BOSA_CAL_GN28L95 = 1,
            AIROHA_BOSA_CAL_UX3363  = 2,
    };

Why the earlier builds failed
-----------------------------
The first attempt was written from a disassembly of airoha-paged-bosa.ko and missed
two checks entirely, because they are crc32_le() calls that look like ordinary
function calls in the listing:

    header_crc  = le32(data + 0x7c)
    payload_crc = le32(data + 0x18)

    (crc32_le(~0U, data, 0x7c) ^ ~0U) != header_crc                  -> -EINVAL
    (crc32_le(~0U, data + header_size, payload_length) ^ ~0U) != payload_crc
                                                                    -> -EBADMSG

It also set calibration_id to 0, but the enum starts at 1, so bosa_chip_by_id(0)
returns NULL and the loader exits with -ENODEV.  -ENODEV is one of the codes that
maps to CALIBRATION_MISSING rather than INVALID, so that alone would have shown
"missing" instead of "invalid" -- and the observed message was "invalid", which
means the header failed an earlier check first.

Complete header layout, all little-endian:

    0x00  char[8]  "APONCAL\\0"
    0x08  u16      1                   AIROHA_BOSA_CAL_VERSION
    0x0a  u16      0x0080              AIROHA_BOSA_CAL_HEADER_SIZE
    0x0c  u32      2                   AIROHA_BOSA_CAL_UX3363
    0x10  u32      1                   AIROHA_BOSA_CAL_NATIVE
    0x14  u32      0x780               payload length
    0x18  u32      crc32 of payload
    0x1c..0x7b     zero
    0x7c  u32      crc32 of bytes 0x00..0x7b
    0x80  ...      payload

The CRC is crc32_le(~0, ...) ^ ~0, which is the standard reflected CRC-32 / IEEE
802.3 that zlib.crc32 computes with no final xor surprise: zlib.crc32(data) already
applies the same initial and final inversion.

Payload layout, from ux3363_apply in airoha-paged-bosa-ux3363.c:

    page 0x81, first 0x80, 105 B  <- data + 0x280
    page 0x82, first 0x80, 105 B  <- data + 0x300
    page 0x83, first 0x80, 105 B  <- data + 0x400
    page 0x84, first 0x80,  84 B  <- data + 0x380
    page 0x84, first 0xd6,   8 B  <- data + 0x3d6
    page 0x84, first 0xe0,  11 B  <- data + 0x3e0
    page 0x00, first 0x00, 123 B  <- data + 0x100
    page 0x80, regs 0x80..0xee    <- data[0x200 + n], n in 0..110

data[0x000..0x0ff] and data[0x469..0x77f] are never read.

What this script can and cannot do
----------------------------------
It builds a container whose header passes every check.  The payload it fills in comes
from either:

  --payload FILE   a 1920-byte register image, e.g. one read back from the module
                   with tools/read-module-eeprom.sh

  (default)        the vendor fiberhomebdbob table, expanded into the spans the
                   driver writes.  This is a best-effort guess: the vendor table is a
                   different format, but its per-page data is the closest thing
                   available on a unit that has never run a calibrated Airoha image.

A header-only container (--payload zero) is also useful: it makes the driver report
CALIBRATION_READY, which confirms the container format is right before spending time
on payload semantics.
"""

import argparse
import pathlib
import struct
import sys
import zlib

MAGIC = b'APONCAL\x00'
VERSION = 1
HEADER_SIZE = 0x80
NATIVE = 1
CHIP_GN28L95 = 1
CHIP_UX3363 = 2

PAYLOAD_LEN = 0x780
VOLUME_SIZE = 0x40000
CELL_OFFSET = 0x2
CELL_SIZE = 0x800

# Where each span of the payload is written, from ux3363_apply.
SPANS = [
    (0x100, 123, 'page 0x00 reg 0x00'),
    (0x200, 111, 'page 0x80 reg 0x80'),
    (0x280, 105, 'page 0x81 reg 0x80'),
    (0x300, 105, 'page 0x82 reg 0x80'),
    (0x380,  84, 'page 0x84 reg 0x80'),
    (0x3D6,   8, 'page 0x84 reg 0xd6'),
    (0x3E0,  11, 'page 0x84 reg 0xe0'),
    (0x400, 105, 'page 0x83 reg 0x80'),
]


def crc32_ieee(data: bytes) -> int:
    """crc32_le(~0, ...) ^ ~0 from linux/crc32.h is plain zlib CRC-32.

    The kernel helper starts with ~0U and the caller xors with ~0U at the end; zlib
    does exactly the same internally, so zlib.crc32 returns the identical value.
    """
    return zlib.crc32(data) & 0xFFFFFFFF


def build_header(payload: bytes, chip_id: int) -> bytes:
    if len(payload) != PAYLOAD_LEN:
        raise ValueError(f'payload must be {PAYLOAD_LEN} bytes, got {len(payload)}')

    hdr = bytearray(HEADER_SIZE)
    hdr[0x00:0x08] = MAGIC
    struct.pack_into('<H', hdr, 0x08, VERSION)
    struct.pack_into('<H', hdr, 0x0a, HEADER_SIZE)
    struct.pack_into('<I', hdr, 0x0c, chip_id)
    struct.pack_into('<I', hdr, 0x10, NATIVE)
    struct.pack_into('<I', hdr, 0x14, len(payload))
    struct.pack_into('<I', hdr, 0x18, crc32_ieee(payload))
    # 0x1c..0x7b stay zero
    struct.pack_into('<I', hdr, 0x7c, crc32_ieee(bytes(hdr[0x00:0x7c])))
    return bytes(hdr)


def verify_container(cell: bytes, chip_id: int) -> list[tuple[str, bool]]:
    """Reimplement every check bosa_load_calibration performs."""
    checks = []
    checks.append(('cell_size >= header_size', len(cell) >= HEADER_SIZE))
    checks.append(('magic == APONCAL\\0', cell[0x00:0x08] == MAGIC))

    version, = struct.unpack_from('<H', cell, 0x08)
    header_size, = struct.unpack_from('<H', cell, 0x0a)
    cal_id, = struct.unpack_from('<I', cell, 0x0c)
    native, = struct.unpack_from('<I', cell, 0x10)
    payload_len, = struct.unpack_from('<I', cell, 0x14)
    payload_crc, = struct.unpack_from('<I', cell, 0x18)
    header_crc, = struct.unpack_from('<I', cell, 0x7c)

    checks.append(('version == 1', version == VERSION))
    checks.append(('header_size == 0x80', header_size == HEADER_SIZE))
    checks.append(('field_0x10 == NATIVE (1)', native == NATIVE))
    checks.append(('payload_len <= cell_size - header_size',
                   payload_len <= len(cell) - header_size))
    checks.append(('header crc32 matches',
                   crc32_ieee(cell[0x00:0x7c]) == header_crc))
    checks.append(('payload crc32 matches',
                   crc32_ieee(cell[header_size:header_size + payload_len]) == payload_crc))
    checks.append((f'calibration_id == {chip_id} ({cal_id})', cal_id == chip_id))
    return checks


def payload_from_vendor_table(table: bytes) -> bytes:
    """Fill the spans ux3363_apply writes from the vendor BDBOB table.

    The vendor table is 2048 bytes of a different format, so this is not a faithful
    conversion.  It spreads the table's per-page content across the spans in order,
    which at least puts plausible bytes in every register the driver will program
    instead of leaving them zero.
    """
    payload = bytearray(PAYLOAD_LEN)
    src = table
    pos = 0
    for off, length, _where in SPANS:
        chunk = src[pos:pos + length]
        if len(chunk) < length:
            chunk = chunk + bytes(length - len(chunk))
        payload[off:off + length] = chunk
        pos += length
    return bytes(payload)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--payload', metavar='FILE',
                    help='1920-byte register image, e.g. from read-module-eeprom.sh; '
                         'the literal "zero" builds an all-zero payload')
    ap.add_argument('--vendor-table', metavar='FILE',
                    default=r'H:\Deepseek\hg5580a-port\backup\bosacal-table-2048.bin',
                    help='vendor fiberhomebdbob table, used when --payload is absent')
    ap.add_argument('--chip', type=int, default=CHIP_UX3363,
                    choices=[CHIP_GN28L95, CHIP_UX3363],
                    help='calibration_id: 1 = GN28L95, 2 = UX3363')
    ap.add_argument('--out', metavar='FILE',
                    default=r'H:\Deepseek\hg5580a-port\uboot-out\bosa-aponcal.bin',
                    help='output volume image')
    args = ap.parse_args()

    source = ''
    if args.payload:
        if args.payload == 'zero':
            payload = bytes(PAYLOAD_LEN)
            source = 'all zero (header-only test)'
        else:
            p = pathlib.Path(args.payload)
            if not p.exists():
                print(f'payload not found: {p}')
                return 1
            payload = p.read_bytes()
            if len(payload) != PAYLOAD_LEN:
                print(f'payload is {len(payload)} bytes, must be exactly {PAYLOAD_LEN}')
                return 1
            source = str(p)
    else:
        p = pathlib.Path(args.vendor_table)
        if not p.exists():
            print(f'vendor table not found: {p}; pass --payload instead')
            return 1
        payload = payload_from_vendor_table(p.read_bytes())
        source = f'{p.name} spread across the driver-writable spans (approximate)'

    header = build_header(payload, args.chip)
    cell = header + payload

    if len(cell) > CELL_SIZE:
        print(f'cell is {len(cell)} bytes, exceeds the {CELL_SIZE} the DTS declares')
        return 1

    volume = bytearray(b'\xff' * VOLUME_SIZE)
    volume[CELL_OFFSET:CELL_OFFSET + len(cell)] = cell

    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(bytes(volume))

    print('APONCAL container built')
    print(f'  output       {out}')
    print(f'  volume       {len(volume)} bytes')
    print(f'  cell at      volume offset 0x{CELL_OFFSET:x}, {CELL_SIZE} bytes declared')
    print(f'  chip id      {args.chip} '
          f'({"UX3363" if args.chip == CHIP_UX3363 else "GN28L95"})')
    print(f'  payload      {len(payload)} bytes from {source}')
    print()
    print('  header:')
    print(f'    0x00  magic   {MAGIC!r}')
    print(f'    0x08  u16     {VERSION}          version')
    print(f'    0x0a  u16     0x{HEADER_SIZE:04x}       header size')
    print(f'    0x0c  u32     {args.chip}          calibration_id')
    print(f'    0x10  u32     {NATIVE}          native')
    print(f'    0x14  u32     {len(payload)}       payload length')
    print(f'    0x18  u32     0x{crc32_ieee(payload):08x}  payload crc32')
    print(f'    0x7c  u32     0x{crc32_ieee(header[0x00:0x7c]):08x}  header crc32')
    print()
    print('  bosa_load_calibration checks:')

    ok = True
    for name, cond in verify_container(cell, args.chip):
        print(f'    [{"OK  " if cond else "FAIL"}] {name}')
        if not cond:
            ok = False

    print()
    print('  payload spans (ux3363_apply):')
    for off, length, where in SPANS:
        print(f'    0x{off:03x}..0x{off + length - 1:03x}  {where:<20} {length:>3} bytes')
    print('    0x000..0x0ff and 0x469..0x77f are never read by the driver')

    print()
    if ok:
        print('RESULT: every check the driver performs will pass.')
        print()
        print('Next:  ubiupdatevol /dev/ubi0_3 <this file>   then power-cycle (not reboot)')
    else:
        print('RESULT: something still does not match; do not flash this file.')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
