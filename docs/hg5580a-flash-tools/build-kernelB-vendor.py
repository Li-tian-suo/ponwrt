#!/usr/bin/env python3
"""Build a vendor-compatible KernelB image from the PonWrt SYSUPGRADE kernel.

Choose the sysupgrade FIT, not the initramfs one:
  initramfs.itb      kernel subimage = 10,775,234 B  -> exceeds KernelX (6 MiB)
  sysupgrade .bin    kernel subimage =  5,905,664 B  gzip -> fits

VENDOR WRAPPER FORMAT (every field verified against backup/mtd-KernelA.bin,
which the box boots successfully):

    file offset                 content
    0x0000                      private header (magic 010064aa 78563412, X.509, "HDR2")
    0x0098                      u32 LE  pad added to the 0xA0 offset
    0x00A0                      u32 LE  offset of the end-of-payload marker
    0x2100                      FIT metadata FDT (vendor reserves 0x1000 bytes)
    payload base = 0x2100 + 0x1000 = 0x3100
    payload     = base + data-offset
    total_size  = *(u32)(0xA0) + *(u32)(0x98)

Verified against KernelA:
    kernel     data-offset 0x4000 -> 0x3100+0x4000 = 0x7100
               sha1 over 5,932,813 B = 5263cf96... (declared) MATCH
               lzma at 0x7100 decompresses to 19,952,128 B
    fdt-1      data-offset 0x0000 -> 0x3100  (a valid FDT, 15,704 B)
    rootfs_env data-offset 0x5ad000 -> 0x5af100 == *(u32)(0xA0) MATCH
"""
import struct, hashlib, os, sys, zlib

VENDOR_A = r'H:\Deepseek\hg5580a-port\backup\mtd-KernelA.bin'
SYSUPGRADE = r'H:\Deepseek\hg5580a-port\backup\fw\built\ponwrt-airoha-an7583-fiberhome_hg5580a-squashfs-sysupgrade.bin'
OUT = r'H:\Deepseek\hg5580a-port\backup\fw\kernelwrap\kernelB-vendor.bin'

FDT_MAGIC = b'\xd0\x0d\xfe\xed'
HDR_END = 0x2100
FIT_AREA = 0x1000
PART = 0x600000

def parse_fit(path):
    d = open(path, 'rb').read()
    assert d[:4] == FDT_MAGIC, "not a FIT"
    w = struct.unpack('>10I', d[:40])
    total, off_struct, off_strings = w[1], w[2], w[3]
    sz_struct, sz_strings = w[9], w[8]
    sbuf = d[off_strings: off_strings + sz_strings]

    def s_at(i):
        e = sbuf.find(b'\0', i)
        return sbuf[i:e if e >= 0 else len(sbuf)].decode('latin1')

    p, end = off_struct, off_struct + sz_struct
    stack = []
    cur = None
    info = {}
    while p + 4 <= end:
        tok = struct.unpack('>I', d[p:p + 4])[0]; p += 4
        if tok == 1:
            z = d.find(b'\0', p)
            nm = d[p:z].decode('latin1'); p = (z + 4) & ~3
            stack.append(nm)
            if len(stack) == 3 and stack[1] == 'images':
                cur = nm
                info[cur] = {}
        elif tok == 2:
            if stack:
                stack.pop()
            if len(stack) < 3:
                cur = None
        elif tok == 3:
            ln, no = struct.unpack('>II', d[p:p + 8]); p += 8
            val = d[p:p + ln]; p = (p + ln + 3) & ~3
            if cur and len(stack) == 3:
                info[cur][s_at(no)] = val
        elif tok == 9:
            break
    return info

def build_fdt(root, total_pad=FIT_AREA):
    """Build the FIT metadata blob.

    IMPORTANT: the vendor reserves a fixed 0x1000-byte area and its FIT header
    declares totalsize = 0x1000, not the actual blob length.  U-Boot computes
    the payload base as FIT_base + totalsize, so totalsize MUST be 0x1000 here
    or every data-offset lands in the wrong place.
    """
    import io
    struct_block = io.BytesIO()
    str_block = io.BytesIO()
    offsets = {}

    def add_str(s):
        if s not in offsets:
            offsets[s] = str_block.tell()
            str_block.write(s.encode() + b'\0')
        return offsets[s]

    def emit(node):
        struct_block.write(struct.pack('>I', 1))
        struct_block.write(node['name'].encode() + b'\0')
        while struct_block.tell() % 4:
            struct_block.write(b'\0')
        for k, v in node.get('props', []):
            struct_block.write(struct.pack('>III', 3, len(v), add_str(k)))
            struct_block.write(v)
            while struct_block.tell() % 4:
                struct_block.write(b'\0')
        for c in node.get('children', []):
            emit(c)
        struct_block.write(struct.pack('>I', 2))

    emit(root)
    struct_block.write(struct.pack('>I', 9))

    sdata, strs = struct_block.getvalue(), str_block.getvalue()
    off_rsv = 40
    off_struct = off_rsv + 16
    off_strings = off_struct + len(sdata)
    actual = off_strings + len(strs)

    # declare the reserved area size so payload_base = FIT + 0x1000
    declared = total_pad
    hdr = struct.pack('>10I', 0xd00dfeed, declared, off_struct, off_strings,
                      off_rsv, 17, 16, 0, len(strs), len(sdata))
    blob = hdr + b'\0' * 16 + sdata + strs
    if len(blob) > declared:
        sys.exit(f"FATAL: FIT content {len(blob)} B exceeds declared {declared} B")
    return blob + b'\0' * (declared - len(blob)), actual

def main():
    vendor = open(VENDOR_A, 'rb').read()
    sub = parse_fit(SYSUPGRADE)

    kname = 'kernel-1' if 'kernel-1' in sub else 'kernel'
    fname = 'fdt-1' if 'fdt-1' in sub else 'fdt'
    kernel = sub[kname]['data']
    dt = sub[fname]['data']
    kcomp = sub[kname].get('compression', b'none').rstrip(b'\0').decode()
    kload = struct.unpack('>I', sub[kname].get('load', struct.pack('>I', 0x80200000)))[0]

    print("=== inputs ===")
    print(f"  vendor KernelA : {len(vendor):,} B")
    print(f"  kernel         : {len(kernel):,} B ({kcomp}, load 0x{kload:08x})")
    print(f"  device tree    : {len(dt):,} B")

    est = HDR_END + FIT_AREA + len(dt) + len(kernel)
    print(f"  estimated size : {est:,} B  vs partition {PART:,} B -> "
          f"{'FITS' if est <= PART else 'TOO BIG'}")
    if est > PART:
        sys.exit("FATAL: kernel too large for KernelX")

    priv = bytearray(vendor[:HDR_END])
    print()
    print("=== private header (kept verbatim) ===")
    print(f"  magic   {priv[0:8].hex()}")
    print(f"  0x98    = 0x{struct.unpack('<I', priv[0x98:0x9c])[0]:08x}")
    print(f"  0xA0    = 0x{struct.unpack('<I', priv[0xa0:0xa4])[0]:08x}")

    dt_off = 0
    kernel_off = (len(dt) + 0xFFF) & ~0xFFF
    kernel_sha1 = hashlib.sha1(kernel).digest()

    print()
    print("=== payload placement (offsets relative to file 0x3100) ===")
    print(f"  fdt     data-offset 0x{dt_off:06x} -> file 0x{HDR_END+FIT_AREA+dt_off:06x}")
    print(f"  kernel  data-offset 0x{kernel_off:06x} -> file 0x{HDR_END+FIT_AREA+kernel_off:06x}"
          f"  ends 0x{HDR_END+FIT_AREA+kernel_off+len(kernel):06x}")
    print(f"  kernel sha1 = {kernel_sha1.hex()}")

    def be32(v):
        return struct.pack('>I', v)

    root = {
        'name': '',
        'props': [('timestamp', be32(0x69766c30)),
                  ('description', b'PonWrt kernel for FiberHome HG5580A\0'),
                  ('#address-cells', be32(1))],
        'children': [
            {'name': 'images', 'props': [], 'children': [
                {'name': fname, 'props': [
                    ('data-size', be32(len(dt))),
                    ('data-offset', be32(dt_off)),
                    ('description', b'PonWrt HG5580A device tree\0'),
                    ('type', b'flat_dt\0'),
                    ('arch', b'arm64\0'),
                    ('compression', b'none\0')], 'children': []},
                {'name': kname, 'props': [
                    ('data-size', be32(len(kernel))),
                    ('data-offset', be32(kernel_off)),
                    ('description', b'PonWrt Linux kernel\0'),
                    ('type', b'kernel\0'),
                    ('arch', b'arm64\0'),
                    ('os', b'linux\0'),
                    ('compression', kcomp.encode() + b'\0'),
                    ('load', be32(kload)),
                    ('entry', be32(kload))],
                 'children': [{'name': 'hash-1', 'props': [
                     ('value', kernel_sha1), ('algo', b'sha1\0')], 'children': []}]},
            ]},
            {'name': 'configurations', 'props': [('default', b'conf-1\0')],
             'children': [{'name': 'conf-1', 'props': [
                 ('description', b'Boot PonWrt kernel with FDT blob\0'),
                 ('fdt', fname.encode() + b'\0'),
                 ('kernel', kname.encode() + b'\0')], 'children': []}]},
        ],
    }

    fit_area, fit_actual = build_fdt(root)
    print()
    print(f"=== FIT metadata: {fit_actual:,} B used, declaring totalsize=0x{FIT_AREA:x} ===")
    print(f"  payload base = 0x{HDR_END:x} + 0x{FIT_AREA:x} = 0x{HDR_END+FIT_AREA:x}")

    body = bytearray()
    body += dt
    body += b'\0' * (kernel_off - len(body))
    body += kernel

    img = bytearray(priv) + bytearray(fit_area) + body
    data_end = HDR_END + FIT_AREA + kernel_off + len(kernel)

    # total_size must cover every non-zero byte.  0xA0 points at the payload
    # end; 0x98 carries the pad that rounds it up to a 0x1000 boundary.
    a0_value = HDR_END + FIT_AREA + kernel_off + len(kernel)
    total_size = (a0_value + 0xFFF) & ~0xFFF
    pad = total_size - a0_value
    struct.pack_into('<I', img, 0x98, pad)
    struct.pack_into('<I', img, 0xA0, a0_value)

    print()
    print("=== length fields written ===")
    print(f"  0x98 pad    = 0x{pad:08x}")
    print(f"  0xA0 offset = 0x{a0_value:08x}")
    print(f"  total_size  = 0x{total_size:08x} ({total_size:,})")
    print(f"  data really ends at 0x{data_end:06x}, zero-padded to 0x{total_size:06x}")

    img += b'\0' * (PART - len(img))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    open(OUT, 'wb').write(img)

    print()
    print(f"=== wrote {os.path.basename(OUT)} ===")
    print(f"  size   {len(img):,} B")
    print(f"  crc32  0x{zlib.crc32(img) & 0xffffffff:08x}")
    print(f"  sha256 {hashlib.sha256(img).hexdigest()}")

if __name__ == '__main__':
    main()
