#!/usr/bin/env python3
"""Fully parse the vendor KernelA image so we can build a valid KernelB.

Bootstrap facts from the running box (A slot boots, B slot fails):
    A: "Read FIT image total_size=5b1100"  then boots
    B: "Read FIT image total_size=21d36ee2" then "Failed to load the image"

and the boot log right after that line:

    INFO: Loading image id=7  at 0x80045000
    INFO:    Image id=7  loaded: 0x80045000 - 0x80045a0e
    INFO: Loading image id=11 at 0x80045000
    INFO:    Image id=11 loaded: 0x80045000 - 0x800457ea
    INFO: Loading image id=15 at 0x80045000
    INFO:    Image id=15 loaded: 0x80045000 - 0x80045682
    ## Loading kernel from FIT Image at 81800000 ...
         Data Start:   0x81805000
         Data Size:    5932732 Bytes
         Load Address: 0x80088000
    ## Loading fdt from FIT Image at 81800000 ...
         Data Start:   0x81801000
         Data Size:    15704 Bytes

So at 0x81800000 there is a proper FIT whose kernel data sits at +0x5000 and
whose fdt sits at +0x1000.  This script checks whether that FIT exists verbatim
inside the KernelA image, and if so at which offset.
"""
import struct, os, sys

A = r'H:\Deepseek\hg5580a-port\backup\mtd-KernelA.bin'

def fdt_header(d, off):
    """Return dict of FDT header fields, or None."""
    if off + 40 > len(d) or d[off:off+4] != b'\xd0\x0d\xfe\xed':
        return None
    f = struct.unpack('>10I', d[off:off+40])
    return dict(totalsize=f[0], off_dt_struct=f[1], off_dt_strings=f[2],
                off_mem_rsvmap=f[3], version=f[4], last_comp_version=f[5],
                boot_cpuid_phys=f[6], size_dt_strings=f[7],
                size_dt_struct=f[8])

def list_fdts(d, lo=0, hi=None):
    hi = hi if hi is not None else len(d)
    out = []
    pos = lo
    while True:
        p = d.find(b'\xd0\x0d\xfe\xed', pos, hi)
        if p < 0:
            break
        out.append(p)
        pos = p + 4
    return out

def main():
    d = open(A, 'rb').read()
    print(f"vendor KernelA: {len(d):,} B (0x{len(d):x})")
    print()

    offs = list_fdts(d)
    print(f"=== {len(offs)} FDT magic(s) ===")
    for o in offs:
        h = fdt_header(d, o)
        if h:
            print(f"  0x{o:06x}  totalsize=0x{h['totalsize']:x} ({h['totalsize']:,})  "
                  f"ver={h['version']}  struct@+0x{h['off_dt_struct']:x} "
                  f"({h['size_dt_struct']} B)  strings@+0x{h['off_dt_strings']:x}")
        else:
            print(f"  0x{o:06x}  (bad header)")
    print()

    # The FIT the bootloader reports sits at 0x81800000 with kernel at +0x5000
    # and fdt at +0x1000.  Search for that exact arrangement.
    print("=== searching for the FIT layout reported by U-Boot ===")
    print("    need: FIT at X, fdt blob at X+0x1000 (15704 B), kernel at X+0x5000")
    for o in offs:
        h = fdt_header(d, o)
        if not h:
            continue
        base = o - 0x1000
        if base < 0:
            continue
        # is there a FIT header at base?
        hb = fdt_header(d, base)
        if not hb:
            continue
        # kernel at base+0x5000?
        koff = base + 0x5000
        print(f"  candidate base=0x{base:x}  FIT totalsize=0x{hb['totalsize']:x}")
        print(f"    fdt  at 0x{base+0x1000:x} totalsize=0x{h['totalsize']:x} "
              f"({'15,704 expected' if h['totalsize']==15704 else 'MISMATCH'})")
        print(f"    kernel data would start at 0x{koff:x}")

    print()
    print("=== is the FIT STORED contiguously, or assembled at load time? ===")
    print("    test: does a valid FIT totalsize at 0x2100 cover the fdt at 0x3100?")
    for o in offs:
        h = fdt_header(d, o)
        if h:
            end = o + h['totalsize']
            print(f"    0x{o:06x} + 0x{h['totalsize']:x} = 0x{end:06x}")

    print()
    print("=== where does the kernel payload actually live? ===")
    # The kernel is lzma compressed, reported Data Size 5932732 = 0x5a87fc.
    # Look for something of that size: search for the ECONET kernel magic used
    # by the vendor loader ("01 00 64 aa" style) and for lzma props.
    KSIZE = 5932732
    print(f"    expected kernel data size = {KSIZE:,} B (0x{KSIZE:x})")
    for cand in (0x6e58, 0x6f00, 0x7000, 0x8000, 0xd000, 0x10000):
        if cand + KSIZE <= len(d):
            tail = d[cand: cand + KSIZE]
            after = d[cand + KSIZE: cand + KSIZE + 16]
            print(f"    candidate 0x{cand:05x}: ends 0x{cand+KSIZE:06x}, "
                  f"next16={after.hex()}  head={tail[:8].hex()}")

    print()
    print("=== lzma properties bytes (0x5d 0x00 0x00) in the image ===")
    pos = 0
    found = []
    while len(found) < 12:
        p = d.find(b'\x5d\x00\x00', pos)
        if p < 0:
            break
        found.append(p)
        pos = p + 1
    print("   " + ', '.join(f'0x{p:x}' for p in found) if found else "   none")

if __name__ == '__main__':
    main()
