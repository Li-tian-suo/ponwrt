#!/usr/bin/env python3
"""Decode the vendor KernelA wrapper correctly.

Previous off-by-one: the FDT header starts with magic, so totalsize is word[1],
not word[0].  Correcting that reveals the layout.

Working hypothesis to verify:
    0x0000            private header (magic 0xAA640001 + X.509 + "HDR2")
    0x2100            FIT metadata FDT  (totalsize 0x1000)   -> loaded at 0x81800000
    0x3100            device tree blob  (15704 B)            -> at FIT+0x1000
    0x7100            kernel lzma data  (5932732 B)          -> at FIT+0x5000
    total_size 0x5b1100 = *(u32)(+0xA0) + *(u32)(+0x98)

U-Boot said:
    Data Start: 0x81805000   kernel   (FIT+0x5000 -> image 0x7100)  MATCH
    Data Start: 0x81801000   fdt      (FIT+0x1000 -> image 0x3100)  MATCH
"""
import struct, os

A = r'H:\Deepseek\hg5580a-port\backup\mtd-KernelA.bin'

FDT_MAGIC = b'\xd0\x0d\xfe\xed'

def hdr(d, off):
    if off + 40 > len(d) or d[off:off+4] != FDT_MAGIC:
        return None
    w = struct.unpack('>10I', d[off:off+40])
    return {
        'magic': w[0], 'totalsize': w[1], 'off_dt_struct': w[2],
        'off_dt_strings': w[3], 'off_mem_rsvmap': w[4], 'version': w[5],
        'last_comp_version': w[6], 'boot_cpuid_phys': w[7],
        'size_dt_strings': w[8], 'size_dt_struct': w[9],
    }

def decode_strings(d, fdt_off, h):
    """Walk the struct block and dump (name, value) for every property."""
    sbase = fdt_off + h['off_dt_strings']
    sbuf = d[sbase: sbase + h['size_dt_strings']]
    def s_at(idx):
        if idx >= len(sbuf):
            return f'<bad idx {idx}>'
        end = sbuf.find(b'\0', idx)
        return sbuf[idx:end if end >= 0 else len(sbuf)].decode('latin1')
    p = fdt_off + h['off_dt_struct']
    end = p + h['size_dt_struct']
    depth = 0
    out = []
    while p < end:
        tok = struct.unpack('>I', d[p:p+4])[0]
        p += 4
        if tok == 1:                     # FDT_BEGIN_NODE
            z = d.find(b'\0', p)
            name = d[p:z].decode('latin1')
            out.append(('  ' * depth) + f'[{name or "/"}]')
            depth += 1
            p = (z + 4) & ~3
        elif tok == 2:                   # FDT_END_NODE
            depth -= 1
        elif tok == 3:                   # FDT_PROP
            ln, nameoff = struct.unpack('>II', d[p:p+8])
            p += 8
            val = d[p:p+ln]
            p = (p + ln + 3) & ~3
            nm = s_at(nameoff)
            if ln == 4:
                shown = f'0x{struct.unpack(">I", val)[0]:08x}'
            elif ln <= 32 and all(32 <= b < 127 or b == 0 for b in val):
                shown = repr(val.rstrip(b'\0').decode('latin1'))
            else:
                shown = f'<{ln} bytes> {val[:24].hex()}'
            out.append(('  ' * depth) + f'{nm} = {shown}')
        elif tok == 4:                   # FDT_NOP
            continue
        elif tok == 9:                   # FDT_END
            break
        else:
            out.append(f'  <unknown token 0x{tok:x} at 0x{p-4:x}>')
            break
    return out

def main():
    d = open(A, 'rb').read()
    print(f"vendor KernelA {len(d):,} B")
    print()

    print("=== FDT headers (corrected offsets) ===")
    for off in (0x2100, 0x3100):
        h = hdr(d, off)
        if not h:
            print(f"  0x{off:x}: no FDT")
            continue
        print(f"  0x{off:05x}  totalsize=0x{h['totalsize']:x} ({h['totalsize']:,})  "
              f"ver={h['version']}.{h['last_comp_version']}  "
              f"struct=0x{h['off_dt_struct']:x}+{h['size_dt_struct']}  "
              f"strings=0x{h['off_dt_strings']:x}+{h['size_dt_strings']}")
    print()

    print("=== contents of the FIT metadata FDT at 0x2100 ===")
    h = hdr(d, 0x2100)
    for line in decode_strings(d, 0x2100, h):
        print("  " + line)
    print()

    print("=== fit the hypothesis ===")
    a0 = struct.unpack('<I', d[0xa0:0xa4])[0]
    v98 = struct.unpack('<I', d[0x98:0x9c])[0]
    print(f"  *(u32)(0xA0) = 0x{a0:08x} ({a0:,})")
    print(f"  *(u32)(0x98) = 0x{v98:08x} ({v98:,})")
    print(f"  sum          = 0x{a0+v98:08x} ({a0+v98:,})   target 0x5b1100 -> "
          f"{'MATCH' if a0+v98 == 0x5b1100 else 'NO'}")
    print()
    KSIZE = 5932732
    print(f"  kernel at 0x7100, size {KSIZE:,} (0x{KSIZE:x}) -> ends 0x{0x7100+KSIZE:x}")
    print(f"  total_size 0x5b1100 -> tail padding 0x{0x5b1100 - (0x7100+KSIZE):x} bytes")
    print()
    print("  does the image have all-zero from 0x5b1100 to 0x600000?",
          set(d[0x5b1100:]) == {0} if len(d) > 0x5b1100 else 'n/a')

if __name__ == '__main__':
    main()
