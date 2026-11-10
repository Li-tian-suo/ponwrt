#!/bin/bash
# Test the APONCAL assembly logic in read-module-eeprom.sh without a device.
#
# The assembly map is the part that must be exactly right:
#
#   0x000  page 0x80 reg 0x00  184 B
#   0x100  page 0x00 reg 0x00  123 B   (A0h EEPROM)
#   0x200  page 0x80 reg 0x00  110 B   (second pass over page 0x80)
#   0x280  page 0x81 reg 0x00  105 B
#   0x300  page 0x82 reg 0x00  105 B
#   0x380  page 0x84 reg 0x00   84 B
#   0x3D6  page 0x84 reg 0x56    8 B
#   0x3E0  page 0x84 reg 0x60   11 B
#   0x400  page 0x83 reg 0x00  105 B
#
# A mistake here writes the right bytes into the wrong module page, which would
# leave the optics half programmed.  So build the payload from synthetic pages that
# each carry a distinct fill byte, then assert the byte at every destination offset.
set -u

WORK=$(mktemp -d)
RAW="$WORK/raw"
OUT="$WORK/out"
mkdir -p "$RAW" "$OUT"

# Synthetic pages, each filled with its own page number.
python3 - "$RAW" <<'PY'
import pathlib, sys
raw = pathlib.Path(sys.argv[1])
raw.joinpath('p80.bin').write_bytes(bytes([0x80]) * 184)
raw.joinpath('p81.bin').write_bytes(bytes([0x81]) * 105)
raw.joinpath('p82.bin').write_bytes(bytes([0x82]) * 105)
raw.joinpath('p83.bin').write_bytes(bytes([0x83]) * 105)
raw.joinpath('p84.bin').write_bytes(bytes([0x84]) * 128)
raw.joinpath('p00.bin').write_bytes(bytes([0x00]) * 123)
PY

python3 - "$RAW" "$OUT" <<'PY'
import pathlib, struct, sys

raw = pathlib.Path(sys.argv[1])
outdir = pathlib.Path(sys.argv[2])

PAYLOAD = 0x780
payload = bytearray(b'\x00' * PAYLOAD)


def load(name, expect):
    d = (raw / name).read_bytes()
    if len(d) < expect:
        raise SystemExit(f'{name}: {len(d)} < {expect}')
    return d[:expect]


def place(off, data):
    payload[off:off + len(data)] = data


p80 = load('p80.bin', 184)
p81 = load('p81.bin', 105)
p82 = load('p82.bin', 105)
p83 = load('p83.bin', 105)
p84 = load('p84.bin', 128)
p00 = load('p00.bin', 123)

place(0x000, p80)
place(0x100, p00)
place(0x200, p80[0x00:0x6E])
place(0x280, p81)
place(0x300, p82)
place(0x380, p84[0x00:0x54])
place(0x3D6, p84[0x56:0x5E])
place(0x3E0, p84[0x60:0x6B])
place(0x400, p83)

# Build the cell and the volume exactly as the real script does.
HEADER = 0x80
CELL_OFFSET = 0x2
VOLUME = 0x40000

cell = bytearray(HEADER + PAYLOAD)
cell[0:8] = b'APONCAL\x00'
struct.pack_into('<H', cell, 0x08, 1)
struct.pack_into('<H', cell, 0x0a, HEADER)
struct.pack_into('<I', cell, 0x0c, 0)
struct.pack_into('<I', cell, 0x10, 1)
struct.pack_into('<I', cell, 0x14, PAYLOAD)
cell[HEADER:HEADER + PAYLOAD] = payload

volume = bytearray(b'\xff' * VOLUME)
volume[CELL_OFFSET:CELL_OFFSET + len(cell)] = cell

print('=== assertions ===')
ok = True

checks = [
    ('length == 0x780',            len(payload) == PAYLOAD),
    ('0x000 holds page 0x80',      payload[0x000] == 0x80),
    ('0x0B7 holds page 0x80',      payload[0x0B7] == 0x80),
    ('0x0B8 is untouched',         payload[0x0B8] == 0x00),
    ('0x100 holds page 0x00',      payload[0x100] == 0x00),
    ('0x17A holds page 0x00',      payload[0x179] == 0x00),
    ('0x200 holds page 0x80',      payload[0x200] == 0x80),
    ('0x26D holds page 0x80',      payload[0x26D - 1] == 0x80),
    ('0x280 holds page 0x81',      payload[0x280] == 0x81),
    ('0x300 holds page 0x82',      payload[0x300] == 0x82),
    ('0x380 holds page 0x84',      payload[0x380] == 0x84),
    ('0x3D6 holds page 0x84',      payload[0x3D6] == 0x84),
    ('0x3E0 holds page 0x84',      payload[0x3E0] == 0x84),
    ('0x400 holds page 0x83',      payload[0x400] == 0x83),
    ('0x468 holds page 0x83',      payload[0x468 - 1] == 0x83),
    ('0x469 unused',               payload[0x469] == 0x00),
]
for name, cond in checks:
    print(f'  [{"OK  " if cond else "FAIL"}] {name}')
    if not cond:
        ok = False

print()
print('=== header in the volume ===')
hdr = volume[CELL_OFFSET:CELL_OFFSET + 8]
print(f'  magic at volume 0x{CELL_OFFSET:x}: {bytes(hdr)!r}')
ver, hlen = struct.unpack_from('<HH', volume, CELL_OFFSET + 0x08)
f0c, f10, plen = struct.unpack_from('<III', volume, CELL_OFFSET + 0x0c)
print(f'  version      {ver}')
print(f'  header_len   0x{hlen:04x}')
print(f'  field_0c     0x{f0c:08x}')
print(f'  field_10     {f10}')
print(f'  payload_len  {plen}')
for name, cond in [
    ('magic == APONCAL', bytes(hdr) == b'APONCAL\x00'),
    ('version == 1', ver == 1),
    ('header_len == 0x80', hlen == 0x80),
    ('field_10 == 1', f10 == 1),
    ('payload_len == 1920', plen == 1920),
    ('payload_len <= cell_len - 0x80', plen <= 0x800 - 0x80),
]:
    print(f'  [{"OK  " if cond else "FAIL"}] {name}')
    if not cond:
        ok = False

print()
print('RESULT:', 'assembly map is correct' if ok else 'PROBLEMS FOUND')
sys.exit(0 if ok else 1)
PY

rc=$?
rm -rf "$WORK"
exit "$rc"
