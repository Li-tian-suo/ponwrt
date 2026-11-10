#!/usr/bin/env python3
"""Build an APONCAL calibration volume image for airoha-paged-bosa.

Two facts decide the layout, and both come from the running system rather than from
guesswork.

1. Where the cell starts
------------------------
The DTS declares:

    ubi-volume-bosa {
            volname = "bosa";
            nvmem-layout {
                    compatible = "fixed-layout";
                    bosa_calibration: calibration@2 { reg = <0x2 0x800>; };
            };
    };

so the driver's nvmem cell is volume bytes 0x2..0x802 and the header must sit at
volume offset 2.  Dumping /dev/ubi0_3 confirms what is there now:

    00000000  ff ff 66 69 62 65 72 68 6f 6d 65 62 64 62 6f 62  |..fiberhomebdbob|

which is the vendor BDBOB table placed at offset 2 -- correct for the DTS, but the
wrong format for this driver.

2. What the cell must contain
-----------------------------
Disassembling bosa_probe in airoha-paged-bosa.ko gives the whole contract:

    134:  ldr  x2, [sp]            ; cell length
    138:  cmp  x2, #0x7f
    13c:  b.ls FAIL                ; length must be > 127
    140:  ldr  x3, [x0]            ; first 8 bytes
    144:  mov  x1, #0x5041         ; 'A','P'
    148:  movk x1, #0x4e4f, lsl 16 ; 'O','N'
    14c:  movk x1, #0x4143, lsl 32 ; 'C','A'
    150:  movk x1, #0x4c,   lsl 48 ; 'L','\\0'
    154:  cmp  x3, x1
    158:  b.ne FAIL                ; magic "APONCAL\\0"
    15c:  ldrh w3, [x0, #10]
    160:  ldr  w4, [x0, #12]
    164:  ldrh w1, [x0, #8]
    168:  cmp  w3, #0x80           ; [0x0a] == 0x80
    16c:  str  w4, [x19, #136]     ; [0x0c] stored at priv+136
    170:  ccmp w1, #0x1, ..., eq   ; [0x08] == 1
    178:  ldr  w1, [x0, #16]
    17c:  cmp  w1, #0x1
    180:  b.ne FAIL                ; [0x10] == 1
    188:  sub  x2, x2, #0x80       ; remaining = cell_len - 0x80
    18c:  ldr  w25, [x0, #20]
    190:  cmp  x25, x2
    194:  b.ls OK                  ; [0x14] <= cell_len - 0x80
    198:  kfree; return -EINVAL

With cell_len = 0x800 that last bound is 0x800 - 0x80 = 0x780 = 1920 bytes, so the
payload field must be at most 1920.  An earlier build set it to 131072 and would
have failed that final check even though the magic was right.

Little-endian struct, offsets relative to the start of the cell:

    0x00  char[8]  "APONCAL\\0"
    0x08  u16      1              version
    0x0a  u16      0x0080         header size
    0x0c  u32      value stored at priv+136
    0x10  u32      1
    0x14  u32      payload length, <= 1920
    0x80  ...      payload

The payload bytes are the vendor BDBOB table.  The probe only validates the header,
so this is enough for the frontend to register; if the line still does not come up,
the coefficients themselves need to come from a unit that reports "calibrated".
"""

import pathlib
import struct
import sys

ART = pathlib.Path(r'H:\Deepseek\hg5580a-port\uboot-out')
VENDOR_TABLE = pathlib.Path(r'H:\Deepseek\hg5580a-port\backup\bosacal-table-2048.bin')

VOLUME_SIZE = 0x40000        # the bosa volume is 262144 bytes
CELL_OFFSET = 0x2            # calibration@2 in the DTS
CELL_SIZE = 0x800            # reg = <0x2 0x800>
HEADER_SIZE = 0x80

MAGIC = b'APONCAL\x00'
VERSION = 1
HEADER_LEN = 0x80
FIELD_0C = 0x00000000
FIELD_10 = 1

# The driver's last check bounds the payload by cell_len - header_len.
MAX_PAYLOAD = CELL_SIZE - HEADER_SIZE       # 1920


def main():
    if not VENDOR_TABLE.exists():
        print(f'vendor table not found: {VENDOR_TABLE}')
        return 1

    vendor = VENDOR_TABLE.read_bytes()
    payload_len = min(len(vendor), MAX_PAYLOAD)
    payload = vendor[:payload_len]

    header = bytearray(HEADER_SIZE)
    header[0:8] = MAGIC
    struct.pack_into('<H', header, 0x08, VERSION)
    struct.pack_into('<H', header, 0x0a, HEADER_LEN)
    struct.pack_into('<I', header, 0x0c, FIELD_0C)
    struct.pack_into('<I', header, 0x10, FIELD_10)
    struct.pack_into('<I', header, 0x14, payload_len)

    cell = bytearray(HEADER_SIZE + payload_len)
    cell[0:HEADER_SIZE] = header
    cell[HEADER_SIZE:HEADER_SIZE + payload_len] = payload

    if len(cell) > CELL_SIZE:
        print(f'cell would be {len(cell)} bytes, larger than the {CELL_SIZE} the DTS declares')
        return 1

    volume = bytearray(b'\xff' * VOLUME_SIZE)
    volume[CELL_OFFSET:CELL_OFFSET + len(cell)] = cell

    out = ART / 'bosa-aponcal.bin'
    out.write_bytes(bytes(volume))

    print('built APONCAL volume image')
    print(f'  file         {out}')
    print(f'  size         {len(volume)} bytes (the bosa volume size)')
    print(f'  cell at      volume offset 0x{CELL_OFFSET:x}, {CELL_SIZE} bytes')
    print(f'  payload      {payload_len} bytes at cell offset 0x{HEADER_SIZE:x}')
    print()
    print('  header, cell-relative:')
    print(f'    0x00  char[8]  {MAGIC!r}')
    print(f'    0x08  u16      {VERSION}          version')
    print(f'    0x0a  u16      0x{HEADER_LEN:04x}       header size')
    print(f'    0x0c  u32      0x{FIELD_0C:08x}  stored at priv+136')
    print(f'    0x10  u32      {FIELD_10}          must be 1')
    print(f'    0x14  u32      {payload_len}       payload length')
    print()
    print('  bosa_probe checks:')
    print(f'    cell_len {CELL_SIZE} > 127                          pass')
    print(f'    magic APONCAL\\0                                pass')
    print(f'    [0x08] == 1                                     pass')
    print(f'    [0x0a] == 0x80                                  pass')
    print(f'    [0x10] == 1                                     pass')
    print(f'    [0x14] {payload_len} <= {MAX_PAYLOAD}                          pass')
    print()
    print('  sanity: first 16 bytes of the cell as the driver will read them')
    abs_off = CELL_OFFSET
    print(f'    volume 0x{abs_off:04x}: '
          + ' '.join(f'{b:02x}' for b in volume[abs_off:abs_off + 16]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
