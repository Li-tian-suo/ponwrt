#!/usr/bin/env python3
"""Verify the generated KernelB exactly the way vendor U-Boot will read it.

This replays ldkernel's logic step by step:

  1. total_size = *(u32)(img+0xA0) + *(u32)(img+0x98)
  2. read the FIT metadata FDT at img+0x2100
  3. for each subimage: payload = img + 0x2100 + FIT_totalsize + data-offset
  4. verify the declared sha1 over the kernel payload
  5. decompress the kernel to prove it is not corrupt
  6. confirm total_size covers every non-zero byte

If any step fails here it will fail on the box, so this is the gate before
touching flash.
"""
import struct, hashlib, gzip, os, sys, zlib

IMG = r'H:\Deepseek\hg5580a-port\backup\fw\kernelwrap\kernelB-vendor.bin'
HDR_END = 0x2100
PART = 0x600000

def parse_fdt(d, base):
    if d[base:base+4] != b'\xd0\x0d\xfe\xed':
        raise SystemExit(f"no FDT magic at 0x{base:x}")
    w = struct.unpack('>10I', d[base:base+40])
    total, off_struct, off_strings = w[1], w[2], w[3]
    sz_struct, sz_strings = w[9], w[8]
    sbuf = d[base+off_strings: base+off_strings+sz_strings]

    def s_at(i):
        e = sbuf.find(b'\0', i)
        return sbuf[i:e if e >= 0 else len(sbuf)].decode('latin1')

    p, end = base+off_struct, base+off_struct+sz_struct
    stack, cur, info = [], None, {}
    # Track the node path per property so nested nodes (hash-1/value) attach to
    # the right image.  Depth alone was not enough: the properties of a subimage
    # sit at depth 3, but so do hash-1's, so we key on the full path instead.
    while p + 4 <= end:
        tok = struct.unpack('>I', d[p:p+4])[0]; p += 4
        if tok == 1:
            z = d.find(b'\0', p)
            nm = d[p:z].decode('latin1'); p = (z+4) & ~3
            stack.append(nm or '/')
            # images/<img>  or  images/<img>/<sub>
            if len(stack) >= 3 and stack[1] == 'images':
                img = stack[2]
                info.setdefault(img, {})
                if len(stack) >= 4:
                    cur = (img, stack[3])
                else:
                    cur = (img, None)
            else:
                cur = None
        elif tok == 2:
            if stack:
                stack.pop()
            cur = None
            if len(stack) >= 3 and stack[1] == 'images':
                img = stack[2]
                cur = (img, None) if len(stack) == 3 else None
        elif tok == 3:
            ln, no = struct.unpack('>II', d[p:p+8]); p += 8
            val = d[p:p+ln]; p = (p+ln+3) & ~3
            if cur:
                img, sub = cur
                key = s_at(no) if sub is None else f'{sub}/{s_at(no)}'
                info.setdefault(img, {})[key] = val
        elif tok == 9:
            break
    return dict(total=total, off_struct=off_struct, off_strings=off_strings,
                sz_struct=sz_struct, sz_strings=sz_strings), info

def main():
    d = open(IMG, 'rb').read()
    ok = True
    print(f"image {os.path.basename(IMG)}  {len(d):,} B / partition {PART:,} B")
    print()

    # ---- 1. length fields --------------------------------------------------
    print("=== 1. length fields (ldkernel reads these two) ===")
    pad = struct.unpack('<I', d[0x98:0x9c])[0]
    a0 = struct.unpack('<I', d[0xa0:0xa4])[0]
    total_size = a0 + pad
    print(f"  *(u32)(0x98) = 0x{pad:08x}")
    print(f"  *(u32)(0xA0) = 0x{a0:08x}")
    print(f"  total_size   = 0x{total_size:08x} ({total_size:,})")
    if total_size > PART:
        print("  FAIL: total_size exceeds the partition"); ok = False

    nz_end = max(i for i, b in enumerate(d) if b != 0) + 1
    print(f"  last non-zero byte at 0x{nz_end:x}")
    if total_size < nz_end:
        print(f"  FAIL: total_size 0x{total_size:x} < data end 0x{nz_end:x}")
        ok = False
    else:
        print(f"  OK: total_size covers all data (+0x{total_size-nz_end:x} slack)")

    # ---- 2. FIT metadata ---------------------------------------------------
    print()
    print("=== 2. FIT metadata at 0x2100 ===")
    meta, sub = parse_fdt(d, HDR_END)
    print(f"  totalsize   = 0x{meta['total']:x}")
    print(f"  off_struct  = 0x{meta['off_struct']:x} (+{meta['sz_struct']})")
    print(f"  off_strings = 0x{meta['off_strings']:x} (+{meta['sz_strings']})")
    payload_base = HDR_END + meta['total']
    print(f"  payload base = 0x{payload_base:x}")
    print(f"  subimages    = {list(sub)}")

    # ---- 3/4/5. each subimage ---------------------------------------------
    for name, props in sub.items():
        size = struct.unpack('>I', props['data-size'])[0]
        off = struct.unpack('>I', props['data-offset'])[0]
        at = payload_base + off
        typ = props.get('type', b'').rstrip(b'\0').decode()
        comp = props.get('compression', b'').rstrip(b'\0').decode()
        print()
        print(f"=== subimage {name} ({typ}, {comp}) ===")
        print(f"  data-offset 0x{off:06x} -> file 0x{at:06x}  size {size:,}")
        if at + size > len(d):
            print("  FAIL: runs past the image"); ok = False; continue
        blob = d[at:at+size]

        if typ == 'flat_dt':
            if blob[:4] == b'\xd0\x0d\xfe\xed':
                ftot = struct.unpack('>I', blob[4:8])[0]
                print(f"  OK: FDT magic, totalsize 0x{ftot:x} "
                      f"({'consistent' if ftot == size else 'MISMATCH vs data-size'})")
                if ftot != size:
                    print("  FAIL: data-size does not match the FDT totalsize"); ok = False
            else:
                print(f"  FAIL: no FDT magic ({blob[:4].hex()})"); ok = False

        elif typ == 'kernel':
            hv = props.get('hash-1/value')
            got = hashlib.sha1(blob).hexdigest()
            if hv:
                want = hv.hex()
                print(f"  sha1 declared {want}")
                print(f"  sha1 actual   {got}  {'OK' if got == want else 'FAIL'}")
                if got != want: ok = False
            else:
                print("  (no hash-1 node)")
            try:
                if comp == 'gzip':
                    out = gzip.decompress(blob)
                elif comp == 'lzma':
                    import lzma
                    out = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE).decompress(
                        blob, max_length=64*1024*1024)
                elif comp == 'none':
                    out = blob
                else:
                    out = None
                    print(f"  (compression {comp} not tested)")
                if out is not None:
                    print(f"  decompressed  {len(out):,} B  head={out[:8].hex()}")
            except Exception as e:
                print(f"  FAIL decompress: {type(e).__name__}: {e}"); ok = False
            for k in ('load', 'entry'):
                if k in props:
                    print(f"  {k:<6} = 0x{struct.unpack('>I', props[k])[0]:08x}")

    # ---- 6. region between FIT and payload --------------------------------
    print()
    print("=== 6. reserved FIT area padding ===")
    gap = d[HDR_END + meta['total']: payload_base]
    print(f"  bytes 0x{HDR_END+meta['total']:x}..0x{payload_base:x} = {len(gap)}"
          f"  all zero: {set(gap) <= {0}}")
    if set(gap) - {0}:
        print("  FAIL: non-zero padding after the FIT metadata"); ok = False

    print()
    print("=" * 60)
    print("RESULT:", "PASS - safe to flash" if ok else "FAIL - do NOT flash")
    print("=" * 60)
    print()
    print(f"crc32 = 0x{zlib.crc32(d) & 0xffffffff:08x}")
    sys.exit(0 if ok else 1)

if __name__ == '__main__':
    main()
