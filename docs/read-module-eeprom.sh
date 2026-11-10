#!/bin/sh
# Read the UX3363 module's EEPROM pages over I2C and assemble an APONCAL payload.
#
# Source of truth
# ---------------
# feeds/pon_drivers/airoha-pon-frontends/src/airoha-paged-bosa-ux3363.c, function
# ux3363_apply.  An earlier version of this script was written from a disassembly and
# got four things wrong; the source settles them:
#
#   WRONG (disassembly)                     RIGHT (source)
#   data[0x000..0x0B7] -> page 0x80 reg 0x00   -- this range is never read at all
#   data[0x200] -> page 0x80 reg 0x00, 110 B    data[0x200] -> page 0x80 reg 0x80, 111 B
#   data[0x3d6] -> page 0x84 reg 0x56           data[0x3d6] -> page 0x84 reg 0xd6
#   data[0x3e0] -> page 0x84 reg 0x60           data[0x3e0] -> page 0x84 reg 0xe0
#   every page's first register is 0x00         pages 0x81-0x84 start at 0x80
#
# The 0xd6/0xe0 mistakes came from folding 0xffffffd6 sign-extended down to 0x56;
# the low eight bits are 0xd6.  The 0x000 slice came from misreading the loop as
# data[value] when it is data[0x200 + value].
#
# The authoritative slice list, all with first=0x80 except page 0x00:
#
#   page 0x81, first 0x80, 105 B  <- data + 0x280
#   page 0x82, first 0x80, 105 B  <- data + 0x300
#   page 0x83, first 0x80, 105 B  <- data + 0x400
#   page 0x84, first 0x80,  84 B  <- data + 0x380
#   page 0x84, first 0xd6,   8 B  <- data + 0x3d6   (0xd4-0xd5 reserved)
#   page 0x84, first 0xe0,  11 B  <- data + 0x3e0   (0xde-0xdf reserved)
#   page 0x00, first 0x00, 123 B  <- data + 0x100
#   page 0x80, regs 0x80..0xee    <- data[0x200 + n] for n in 0..110   (111 B)
#
# data[0x000..0x0ff] and data[0x469..0x77f] are never read.  Length must be exactly
# 0x780 or ux3363_apply returns -EINVAL on its first line.
#
# Wire protocol, from airoha-paged-bosa-main.c and the header constants:
#
#   AIROHA_BOSA_PAGE_SELECT  0x7f    two-byte write: 0x7f, page
#   AIROHA_BOSA_TX_CONTROL   0x6e
#   AIROHA_BOSA_TX_DISABLE   BIT(6)
#   read                     write 1 byte reg, then read N bytes, no stop between
#   write                    two-byte write: reg, value
#
# Usage:  sh read-module-eeprom.sh [outdir]
# Output: $outdir/aponcal-payload.bin   1920-byte payload
#         $outdir/aponcal-volume.bin    262144-byte bosa volume with APONCAL header
#
# This only READS the module.  It never writes to it and never touches flash.

set -u

BUS="${BUS:-0}"
ADDR="${ADDR:-0x51}"
OUTDIR="${1:-/tmp/pagedump}"

mkdir -p "$OUTDIR" || exit 1

if ! command -v i2ctransfer >/dev/null 2>&1; then
	echo "i2ctransfer not found; install i2c-tools (opkg install i2c-tools)" >&2
	exit 1
fi

echo "reading module at i2c-$BUS addr $ADDR"

TMP="$OUTDIR/raw"
mkdir -p "$TMP" || exit 1

fail=0

# select_page PAGE
select_page() {
	i2ctransfer -y "$BUS" "w2@$ADDR" 0x7f "$1" >/dev/null 2>&1
}

# read_from PAGE REG LEN DEST
# Reads LEN bytes starting at REG, after selecting PAGE.
read_from() {
	page="$1"; reg="$2"; len="$3"; dest="$4"
	if ! select_page "$page"; then
		echo "  page 0x$page select failed" >&2
		return 1
	fi
	if ! i2ctransfer -y "$BUS" "w1@$ADDR" "$reg" "r$len" > "$dest" 2>/dev/null; then
		echo "  page 0x$page reg 0x$reg read failed" >&2
		return 1
	fi
	got=$(wc -c < "$dest")
	if [ "$got" -ne "$len" ]; then
		echo "  page 0x$page reg 0x$reg short read: $got of $len" >&2
		return 1
	fi
	printf '  page 0x%s reg 0x%s  %s bytes\n' "$page" "$reg" "$got"
	return 0
}

# The register file is written from the module's own pages, reading each region at
# the same page/register the driver writes it to.
read_from 00 00 123 "$TMP/p00_r00.bin" || fail=1
read_from 80 80 111 "$TMP/p80_r80.bin" || fail=1
read_from 81 80 105 "$TMP/p81_r80.bin" || fail=1
read_from 82 80 105 "$TMP/p82_r80.bin" || fail=1
read_from 83 80 105 "$TMP/p83_r80.bin" || fail=1
read_from 84 80  84 "$TMP/p84_r80.bin" || fail=1
read_from 84 d6   8 "$TMP/p84_rd6.bin" || fail=1
read_from 84 e0  11 "$TMP/p84_re0.bin" || fail=1

if [ "$fail" -ne 0 ]; then
	echo
	echo 'one or more regions could not be read; not assembling a partial payload'
	exit 1
fi

# ---------------------------------------------------------------------------
# Assemble the 1920-byte payload at the offsets ux3363_apply expects.
python3 - "$TMP" "$OUTDIR" <<'PY'
import pathlib
import struct
import sys

tmp = pathlib.Path(sys.argv[1])
outdir = pathlib.Path(sys.argv[2])

PAYLOAD = 0x780
payload = bytearray(b'\x00' * PAYLOAD)


def load(name, expect):
    d = (tmp / name).read_bytes()
    if len(d) != expect:
        raise SystemExit(f'{name}: {len(d)} bytes, expected {expect}')
    return d


def place(off, data):
    payload[off:off + len(data)] = data


# Read exactly the spans the driver writes, from the register it writes them to.
place(0x100, load('p00_r00.bin', 123))    # page 0x00, first 0x00
place(0x200, load('p80_r80.bin', 111))    # page 0x80, regs 0x80..0xee
place(0x280, load('p81_r80.bin', 105))    # page 0x81, first 0x80
place(0x300, load('p82_r80.bin', 105))    # page 0x82, first 0x80
place(0x380, load('p84_r80.bin', 84))     # page 0x84, first 0x80
place(0x3D6, load('p84_rd6.bin', 8))      # page 0x84, first 0xd6
place(0x3E0, load('p84_re0.bin', 11))     # page 0x84, first 0xe0
place(0x400, load('p83_r80.bin', 105))    # page 0x83, first 0x80

payload_path = outdir / 'aponcal-payload.bin'
payload_path.write_bytes(bytes(payload))

HEADER = 0x80
CELL_OFFSET = 0x2
VOLUME = 0x40000

cell = bytearray(HEADER + PAYLOAD)
cell[0:8] = b'APONCAL\x00'
struct.pack_into('<H', cell, 0x08, 1)
struct.pack_into('<H', cell, 0x0a, HEADER)
struct.pack_into('<I', cell, 0x0c, 2)          # AIROHA_BOSA_CAL_UX3363
struct.pack_into('<I', cell, 0x10, 1)
struct.pack_into('<I', cell, 0x14, PAYLOAD)
cell[HEADER:HEADER + PAYLOAD] = payload

volume = bytearray(b'\xff' * VOLUME)
volume[CELL_OFFSET:CELL_OFFSET + len(cell)] = cell

volume_path = outdir / 'aponcal-volume.bin'
volume_path.write_bytes(bytes(volume))

USED = [
    (0x100, 0x17A, 'page 0x00 reg 0x00', 123),
    (0x200, 0x26E, 'page 0x80 reg 0x80', 111),
    (0x280, 0x2E8, 'page 0x81 reg 0x80', 105),
    (0x300, 0x368, 'page 0x82 reg 0x80', 105),
    (0x380, 0x3D3, 'page 0x84 reg 0x80',  84),
    (0x3D6, 0x3DD, 'page 0x84 reg 0xd6',   8),
    (0x3E0, 0x3EA, 'page 0x84 reg 0xe0',  11),
    (0x400, 0x468, 'page 0x83 reg 0x80', 105),
]

print()
print(f'payload  {payload_path}  {len(payload)} bytes')
print(f'volume   {volume_path}  {len(volume)} bytes')
print()
print(f'length == 0x780 : {len(payload) == PAYLOAD}')
print()
print('spans the driver reads:')
for lo, hi, where, n in USED:
    print(f'  0x{lo:03x}..0x{hi:03x}  {where:<20} {n:>3} bytes')
print()
print('  0x000..0x0ff  never read by ux3363_apply')
print('  0x469..0x77f  never read by ux3363_apply')
print()
print(f'calibration_id set to 2 (AIROHA_BOSA_CAL_UX3363)')
PY

rc=$?
echo
if [ "$rc" -eq 0 ]; then
	echo "done; verify the header with:"
	echo "  hexdump -C $OUTDIR/aponcal-volume.bin | head -8"
fi
exit "$rc"
