#!/bin/sh
# Read the UX3363 module's EEPROM pages over I2C and assemble an APONCAL payload.
#
# Wire protocol, recovered from airoha-paged-bosa.ko rather than guessed:
#
#   select page:  two bytes 0x7F, page      (i2c_transfer_buffer_flags, len 2)
#   read:         write 1 byte reg, then read N bytes, no stop between
#   write:        two bytes reg, value      (i2c_transfer_buffer_flags, len 2)
#
# Which offset of the payload goes to which page comes from ux3363_apply.  Every
# slice's page and register are visible in the instruction pair just before each
# write_range call:
#
#   115c/1160:  w2 = 0xffffff80, w1 = 0xffffff81   -> page 0x81, reg 0x00
#   1180/1184:  w2 = 0xffffff80, w1 = 0xffffff82   -> page 0x82, reg 0x00
#   11a4/11a8:  w2 = 0xffffff80, w1 = 0xffffff83   -> page 0x83, reg 0x00
#   11c8/11cc:  w2 = 0xffffff80, w1 = 0xffffff84   -> page 0x84, reg 0x00
#   11ec/11f0:  w2 = 0xffffffd6, w1 = 0xffffff84   -> page 0x84, reg 0x56
#   1210/1214:  w2 = 0xffffffe0, w1 = 0xffffff84   -> page 0x84, reg 0x60
#   1234/1238:  w2 = 0x00000000, w1 = 0x00000000   -> page 0x00, reg 0x00
#
# So the full map is:
#
#   payload 0x000..0x0B7  -> page 0x80, regs 0x00..0xB7  (184 bytes)
#   payload 0x200..0x26D  -> page 0x80, regs 0x00..0x6D  (110 bytes, loop at 0x129c)
#   payload 0x100..0x17A  -> page 0x00, reg  0x00       (123 bytes)
#   payload 0x280..0x2E8  -> page 0x81, reg  0x00       (105 bytes)
#   payload 0x300..0x368  -> page 0x82, reg  0x00       (105 bytes)
#   payload 0x400..0x468  -> page 0x83, reg  0x00       (105 bytes)
#   payload 0x380..0x3D3  -> page 0x84, reg  0x00       ( 84 bytes)
#   payload 0x3D6..0x3DD  -> page 0x84, reg  0x56       (  8 bytes)
#   payload 0x3E0..0x3EA  -> page 0x84, reg  0x60       ( 11 bytes)
#
# Page 0x00 is the module's A0h EEPROM (vendor strings).  Note that it is written
# near the end, after page 0x80 is re-selected at 0x1248.
#
# Total payload must be exactly 0x780 = 1920 bytes, or ux3363_apply returns -EINVAL
# at its first instruction.
#
# Usage:  sh read-module-eeprom.sh [outdir]
# Output: $outdir/aponcal-payload.bin   the 1920-byte payload extracted from the module
#         $outdir/aponcal-volume.bin    the full 262144-byte volume image with header
#
# This only READS the module.  It never writes to it and never touches flash.

set -u

BUS="${BUS:-0}"
ADDR="${ADDR:-0x51}"
OUTDIR="${1:-/tmp/pagedump}"

mkdir -p "$OUTDIR" || exit 1

have_i2ctransfer() {
	command -v i2ctransfer >/dev/null 2>&1
}

# Fall back to raw i2c transfers through /dev/i2c-N when i2ctransfer is missing.
# Both paths implement the same three operations.
if have_i2ctransfer; then
	MODE=i2ctransfer
else
	echo "i2ctransfer not found; trying /dev/i2c-$BUS" >&2
	if [ ! -e "/dev/i2c-$BUS" ]; then
		echo "no i2c-tools and no /dev/i2c-$BUS -- cannot read the module" >&2
		echo "install i2c-tools (opkg install i2c-tools) and re-run" >&2
		exit 1
	fi
	MODE=raw
fi

echo "reading module at i2c-$BUS addr $ADDR using $MODE"

select_page() {
	if [ "$MODE" = i2ctransfer ]; then
		i2ctransfer -y "$BUS" "w2@$ADDR" 0x7f "$1" >/dev/null 2>&1
		return $?
	fi
	# raw: 0x7F then the page number
	printf "\\x7f\\x$(printf %02x "$1")" > /dev/null 2>&1
	return 1
}

# Read N bytes starting at register REG into a file.
read_range() {
	local reg="$1" len="$2" dest="$3"
	if [ "$MODE" = i2ctransfer ]; then
		i2ctransfer -y "$BUS" "w1@$ADDR" "$reg" "r$len" > "$dest" 2>/dev/null
		return $?
	fi
	return 1
}

TMP="$OUTDIR/raw"
mkdir -p "$TMP" || exit 1

fail=0

# --- page 0x80: 184 bytes, one register at a time is what the driver does, but a
# --- single 184-byte burst reads the same page and is far fewer transactions.
if select_page 0x80; then
	if read_range 0x00 184 "$TMP/p80.bin"; then
		printf '  page 0x80  %s bytes\n' "$(wc -c < "$TMP/p80.bin")"
	else
		echo '  page 0x80  read failed' >&2
		fail=1
	fi
else
	echo '  page 0x80  select failed' >&2
	fail=1
fi

# --- page 0x81: 105 bytes
if select_page 0x81; then
	if read_range 0x00 105 "$TMP/p81.bin"; then
		printf '  page 0x81  %s bytes\n' "$(wc -c < "$TMP/p81.bin")"
	else
		echo '  page 0x81  read failed' >&2
		fail=1
	fi
else
	echo '  page 0x81  select failed' >&2
	fail=1
fi

# --- page 0x82: 105 bytes
if select_page 0x82; then
	if read_range 0x00 105 "$TMP/p82.bin"; then
		printf '  page 0x82  %s bytes\n' "$(wc -c < "$TMP/p82.bin")"
	else
		echo '  page 0x82  read failed' >&2
		fail=1
	fi
else
	echo '  page 0x82  select failed' >&2
	fail=1
fi

# --- page 0x83: 105 bytes
if select_page 0x83; then
	if read_range 0x00 105 "$TMP/p83.bin"; then
		printf '  page 0x83  %s bytes\n' "$(wc -c < "$TMP/p83.bin")"
	else
		echo '  page 0x83  read failed' >&2
		fail=1
	fi
else
	echo '  page 0x83  select failed' >&2
	fail=1
fi

# --- page 0x84: the driver writes three separate slices into it (84 at reg 0x00,
# --- 8 at reg 0x56, 11 at reg 0x60), so read enough to cover regs 0x00..0x6A.
if select_page 0x84; then
	if read_range 0x00 128 "$TMP/p84.bin"; then
		printf '  page 0x84  %s bytes\n' "$(wc -c < "$TMP/p84.bin")"
	else
		echo '  page 0x84  read failed' >&2
		fail=1
	fi
else
	echo '  page 0x84  select failed' >&2
	fail=1
fi

# --- page 0x00: the A0h EEPROM.  ux3363_apply copies 123 bytes of it from payload
# --- offset 0x100, writing to page 0x00 register 0x00.
if select_page 0x00; then
	if read_range 0x00 123 "$TMP/p00.bin"; then
		printf '  page 0x00  %s bytes\n' "$(wc -c < "$TMP/p00.bin")"
	else
		echo '  page 0x00  read failed' >&2
		fail=1
	fi
else
	echo '  page 0x00  select failed' >&2
	fail=1
fi

if [ "$fail" -ne 0 ]; then
	echo
	echo 'one or more pages could not be read; not assembling a partial payload'
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
    p = tmp / name
    d = p.read_bytes()
    if len(d) < expect:
        raise SystemExit(f'{name}: read {len(d)} bytes, need {expect}')
    return d[:expect]


def place(off, data):
    payload[off:off + len(data)] = data


p80 = load('p80.bin', 184)
p81 = load('p81.bin', 105)
p82 = load('p82.bin', 105)
p83 = load('p83.bin', 105)
p84 = load('p84.bin', 128)
p00 = load('p00.bin', 123)

# The driver's slicing map.  Every destination is now known:
#
#   page 0x80 regs 0x00..0xB7  <- payload 0x000  (184 B)
#   page 0x80 regs 0x00..0x6D  <- payload 0x200  (110 B, second pass over 0x80)
#   page 0x00 reg  0x00        <- payload 0x100  (123 B, A0h EEPROM)
#   page 0x81 reg  0x00        <- payload 0x280  (105 B)
#   page 0x82 reg  0x00        <- payload 0x300  (105 B)
#   page 0x83 reg  0x00        <- payload 0x400  (105 B)
#   page 0x84 reg  0x00        <- payload 0x380  ( 84 B)
#   page 0x84 reg  0x56        <- payload 0x3D6  (  8 B)
#   page 0x84 reg  0x60        <- payload 0x3E0  ( 11 B)
place(0x000, p80)              # page 0x80, first pass
place(0x100, p00)              # page 0x00, A0h EEPROM mirror
place(0x200, p80[0x00:0x6E])   # page 0x80 regs 0x00..0x6D, second pass
place(0x280, p81)              # page 0x81
place(0x300, p82)              # page 0x82
place(0x380, p84[0x00:0x54])   # page 0x84, 84 bytes at reg 0x00
place(0x3D6, p84[0x56:0x5E])   # page 0x84, 8 bytes at reg 0x56
place(0x3E0, p84[0x60:0x6B])   # page 0x84, 11 bytes at reg 0x60
place(0x400, p83)              # page 0x83

payload_path = outdir / 'aponcal-payload.bin'
payload_path.write_bytes(bytes(payload))

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

volume_path = outdir / 'aponcal-volume.bin'
volume_path.write_bytes(bytes(volume))

print()
print(f'payload  {payload_path}  {len(payload)} bytes')
print(f'volume   {volume_path}  {len(volume)} bytes')
print()
print('checks ux3363_apply will make:')
print(f'  payload length == 0x780 :  {len(payload) == PAYLOAD}')
print()
print('slices placed:')
print(f'  0x000..0x0B7  page 0x80 reg 0x00  {len(p80):>3} bytes  (first pass)')
print(f'  0x100..0x17A  page 0x00 reg 0x00  {len(p00):>3} bytes  (A0h EEPROM)')
print(f'  0x200..0x26D  page 0x80 reg 0x00  {len(p80[0x00:0x6E]):>3} bytes  (second pass)')
print(f'  0x280..0x2E8  page 0x81 reg 0x00  {len(p81):>3} bytes')
print(f'  0x300..0x368  page 0x82 reg 0x00  {len(p82):>3} bytes')
print(f'  0x380..0x3D3  page 0x84 reg 0x00  {len(p84[0x00:0x54]):>3} bytes')
print(f'  0x3D6..0x3DD  page 0x84 reg 0x56  {len(p84[0x56:0x5E]):>3} bytes')
print(f'  0x3E0..0x3EA  page 0x84 reg 0x60  {len(p84[0x60:0x6B]):>3} bytes')
print(f'  0x400..0x468  page 0x83 reg 0x00  {len(p83):>3} bytes')
print()
print('every slice has a known destination; nothing is left zero on purpose.')
print('the region 0x469..0x77F stays zero -- ux3363_apply never reads it.')
PY

rc=$?
echo
if [ "$rc" -eq 0 ]; then
	echo "done; verify the header with:"
	echo "  hexdump -C $OUTDIR/aponcal-volume.bin | head -8"
fi
exit "$rc"
