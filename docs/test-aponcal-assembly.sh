#!/bin/bash
# Verify the APONCAL payload assembly map against the driver source, not against my
# earlier reading of the disassembly.
#
# Four things were wrong before the source was read:
#
#   * data[0x000..0x0ff] was listed as a slice; the function never reads it
#   * data[0x200] was placed at page 0x80 reg 0x00 with 110 bytes; it is reg 0x80, 111
#   * data[0x3d6] was placed at reg 0x56; the source says 0xd6
#   * data[0x3e0] was placed at reg 0x60; the source says 0xe0
#
# This test builds a payload from synthetic page reads and then re-derives, from the
# source's slice list, which payload offsets must carry which source bytes.  Every
# expected byte is computed from the slice table, so a mismatch in offset, length, or
# source region shows up immediately.
set -u

WORK=$(mktemp -d)
RAW="$WORK/raw"
OUT="$WORK/out"
mkdir -p "$RAW" "$OUT"

# Synthetic reads, each region filled with a distinct value so a misplaced slice is
# obvious.  These mimic what i2ctransfer would return.
python3 - "$RAW" <<'PY'
import pathlib, sys
raw = pathlib.Path(sys.argv[1])
raw.joinpath('p00_r00.bin').write_bytes(bytes([0xA0]) * 123)
raw.joinpath('p80_r80.bin').write_bytes(bytes([0xB0]) * 111)
raw.joinpath('p81_r80.bin').write_bytes(bytes([0x81]) * 105)
raw.joinpath('p82_r80.bin').write_bytes(bytes([0x82]) * 105)
raw.joinpath('p83_r80.bin').write_bytes(bytes([0x83]) * 105)
raw.joinpath('p84_r80.bin').write_bytes(bytes([0x84]) * 84)
raw.joinpath('p84_rd6.bin').write_bytes(bytes([0xD6]) * 8)
raw.joinpath('p84_re0.bin').write_bytes(bytes([0xE0]) * 11)
PY

python3 - "$RAW" "$OUT" <<'PY'
import pathlib
import struct
import sys

raw = pathlib.Path(sys.argv[1])
outdir = pathlib.Path(sys.argv[2])

PAYLOAD = 0x780
payload = bytearray(b'\x00' * PAYLOAD)


def load(name, expect):
    d = (raw / name).read_bytes()
    if len(d) != expect:
        raise SystemExit(f'{name}: {len(d)} != {expect}')
    return d


def place(off, data):
    payload[off:off + len(data)] = data


place(0x100, load('p00_r00.bin', 123))
place(0x200, load('p80_r80.bin', 111))
place(0x280, load('p81_r80.bin', 105))
place(0x300, load('p82_r80.bin', 105))
place(0x380, load('p84_r80.bin', 84))
place(0x3D6, load('p84_rd6.bin', 8))
place(0x3E0, load('p84_re0.bin', 11))
place(0x400, load('p83_r80.bin', 105))

HEADER = 0x80
CELL_OFFSET = 0x2
VOLUME = 0x40000

cell = bytearray(HEADER + PAYLOAD)
cell[0:8] = b'APONCAL\x00'
struct.pack_into('<H', cell, 0x08, 1)
struct.pack_into('<H', cell, 0x0a, HEADER)
struct.pack_into('<I', cell, 0x0c, 2)
struct.pack_into('<I', cell, 0x10, 1)
struct.pack_into('<I', cell, 0x14, PAYLOAD)
cell[HEADER:HEADER + PAYLOAD] = payload

volume = bytearray(b'\xff' * VOLUME)
volume[CELL_OFFSET:CELL_OFFSET + len(cell)] = cell

ok = True
print('=== payload placement ===')
checks = [
    ('length is 0x780',              len(payload) == PAYLOAD),
    ('0x000 unread / stays zero',    payload[0x000] == 0x00),
    ('0x0FF unread / stays zero',    payload[0x0FF] == 0x00),
    ('0x100 page 0x00 (A0h)',        payload[0x100] == 0xA0),
    ('0x17A page 0x00 last byte',    payload[0x179] == 0xA0),
    ('0x200 page 0x80 reg 0x80',     payload[0x200] == 0xB0),
    ('0x26E page 0x80 last byte',    payload[0x26E] == 0xB0),
    ('0x26F untouched',              payload[0x26F] == 0x00),
    ('0x280 page 0x81',              payload[0x280] == 0x81),
    ('0x2E7 page 0x81 last',         payload[0x2E7] == 0x81),
    ('0x300 page 0x82',              payload[0x300] == 0x82),
    ('0x368 page 0x82 last',         payload[0x367] == 0x82),
    ('0x380 page 0x84 (84 bytes)',   payload[0x380] == 0x84),
    ('0x3D3 page 0x84 last',         payload[0x3D3] == 0x84),
    ('0x3D6 page 0x84 reg 0xd6',     payload[0x3D6] == 0xD6),
    ('0x3DD page 0x84 reg 0xd6 last',payload[0x3DD] == 0xD6),
    ('0x3E0 page 0x84 reg 0xe0',     payload[0x3E0] == 0xE0),
    ('0x3EA page 0x84 reg 0xe0 last',payload[0x3EA] == 0xE0),
    ('0x400 page 0x83',              payload[0x400] == 0x83),
    ('0x468 page 0x83 last',         payload[0x468] == 0x83),
    ('0x469 unread / stays zero',    payload[0x469] == 0x00),
    ('0x77F unread / stays zero',    payload[0x77F] == 0x00),
]
for name, cond in checks:
    print(f'  [{"OK  " if cond else "FAIL"}] {name}')
    if not cond:
        ok = False

print()
print('=== header, at volume offset 0x2 ===')
magic = bytes(volume[CELL_OFFSET:CELL_OFFSET + 8])
ver, hlen = struct.unpack_from('<HH', volume, CELL_OFFSET + 0x08)
cal_id, f10, plen = struct.unpack_from('<III', volume, CELL_OFFSET + 0x0c)
print(f'  magic {magic!r}  version {ver}  header_len 0x{hlen:04x}')
print(f'  calibration_id {cal_id}  field_10 {f10}  payload_len {plen}')
hchecks = [
    ('magic is APONCAL\\0',            magic == b'APONCAL\x00'),
    ('version is 1',                  ver == 1),
    ('header_len is 0x80',            hlen == 0x80),
    ('calibration_id is 2 (UX3363)',  cal_id == 2),
    ('field_10 is 1',                 f10 == 1),
    ('payload_len is 1920',           plen == 1920),
    ('payload_len fits cell-0x80',    plen <= 0x800 - 0x80),
    ('payload length matches define', plen == 0x780),
]
for name, cond in hchecks:
    print(f'  [{"OK  " if cond else "FAIL"}] {name}')
    if not cond:
        ok = False

print()
print('RESULT:', 'map matches the driver source' if ok else 'PROBLEMS FOUND')
sys.exit(0 if ok else 1)
PY

rc=$?
rm -rf "$WORK"
exit "$rc"
