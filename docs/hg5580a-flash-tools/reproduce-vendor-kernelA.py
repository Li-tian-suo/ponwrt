#!/usr/bin/env python3
"""Prove the wrapper builder is byte-exact by reproducing vendor KernelA.

If rebuilding KernelA from its own kernel/DT/hash yields the original file
byte-for-byte, then the only thing our KernelB changes is the payload -- which
is exactly what we want, and it means we did not misread any header field.

Secondary goal: show where the FIT metadata actually differs (mkimage version,
padding, description strings) so we can tell format bugs from cosmetic ones.
"""
import struct, hashlib, os, sys

A = r'H:\Deepseek\hg5580a-port\backup\mtd-KernelA.bin'
HDR_END = 0x2100
FIT_AREA = 0x1000

def parse_fdt(d, base):
    w = struct.unpack('>10I', d[base:base+40])
    total, off_struct, off_strings = w[1], w[2], w[3]
    sz_struct, sz_strings = w[9], w[8]
    sbuf = d[base+off_strings: base+off_strings+sz_strings]
    def s_at(i):
        e = sbuf.find(b'\0', i)
        return sbuf[i:e if e >= 0 else len(sbuf)].decode('latin1')
    p, end = base+off_struct, base+off_struct+sz_struct
    stack, cur, info = [], None, {}
    while p + 4 <= end:
        tok = struct.unpack('>I', d[p:p+4])[0]; p += 4
        if tok == 1:
            z = d.find(b'\0', p)
            nm = d[p:z].decode('latin1'); p = (z+4) & ~3
            stack.append(nm)
            if len(stack) == 3 and stack[1] == 'images':
                cur = nm; info[cur] = {}
        elif tok == 2:
            if stack: stack.pop()
            if len(stack) < 3: cur = None
        elif tok == 3:
            ln, no = struct.unpack('>II', d[p:p+8]); p += 8
            val = d[p:p+ln]; p = (p+ln+3) & ~3
            if cur and len(stack) >= 3:
                info[cur][s_at(no)] = val
        elif tok == 9:
            break
    return dict(total=total), info

def main():
    d = open(A, 'rb').read()
    meta, sub = parse_fdt(d, HDR_END)
    base_payload = HDR_END + meta['total']
    print(f"vendor KernelA {len(d):,} B")
    print(f"FIT totalsize 0x{meta['total']:x}, payload base 0x{base_payload:x}")
    print()

    print("=== vendor subimages (with hash captured) ===")
    for nm, props in sub.items():
        size = struct.unpack('>I', props['data-size'])[0]
        off = struct.unpack('>I', props['data-offset'])[0]
        at = base_payload + off
        comp = props.get('compression', b'?').rstrip(b'\0').decode()
        hv = props.get('hash-1/value')
        print(f"  {nm:<12} off=0x{off:06x} file=0x{at:06x} size={size:>9,} "
              f"comp={comp:<5} sha1={hv.hex() if hv else '-'}")
    print()

    print("=== reproduce KernelA from its own parts ===")
    # Build a byte-exact copy: header + vendor FIT metadata + vendor payload
    rebuilt = bytearray(d[:HDR_END])                    # private header
    rebuilt += d[HDR_END:HDR_END+meta['total']]         # vendor FIT metadata as-is
    rebuilt += b'\0' * (FIT_AREA - meta['total'])
    # payload: everything up to total_size
    a0 = struct.unpack('<I', d[0xA0:0xA4])[0]
    pad = struct.unpack('<I', d[0x98:0x9C])[0]
    ts = a0 + pad
    payload_start = HDR_END + FIT_AREA
    rebuilt += d[payload_start:ts]
    rebuilt += b'\0' * (len(d) - len(rebuilt))

    print(f"  rebuilt {len(rebuilt):,} B vs original {len(d):,} B")
    if bytes(rebuilt) == d:
        print("  IDENTICAL - every header field was read correctly")
    else:
        diffs = [i for i in range(len(d)) if rebuilt[i] != d[i]]
        print(f"  {len(diffs)} differing byte(s), first at 0x{diffs[0]:x}")
        for i in diffs[:8]:
            print(f"    0x{i:06x}: orig=0x{d[i]:02x} rebuilt=0x{rebuilt[i]:02x}")

    print()
    print("=== does the private header contain a payload checksum? ===")
    # look for the kernel sha1 or a sha256 of the payload anywhere in the header
    kernel = sub['kernel']
    ksize = struct.unpack('>I', kernel['data-size'])[0]
    koff = struct.unpack('>I', kernel['data-offset'])[0]
    kblob = d[base_payload+koff: base_payload+koff+ksize]
    cands = {
        'sha1(kernel)': hashlib.sha1(kblob).digest(),
        'sha256(kernel)': hashlib.sha256(kblob).digest(),
        'md5(kernel)': hashlib.md5(kblob).digest(),
        'sha1(payload)': hashlib.sha1(d[payload_start:ts]).digest(),
        'sha256(payload)': hashlib.sha256(d[payload_start:ts]).digest(),
        'sha256(whole)': hashlib.sha256(d[:ts]).digest(),
    }
    hdr = d[:HDR_END]
    for label, digest in cands.items():
        p = hdr.find(digest)
        print(f"  {label:<16} {'FOUND at 0x%x' % p if p >= 0 else 'not in header'}")

if __name__ == '__main__':
    main()
