#!/usr/bin/env python3
"""Wrap an OpenWrt FIT into the vendor KernelA/KernelB container format.

FiberHome's U-Boot 2023.04 does NOT boot a bare FIT in KernelX.  `ldkernel`
expects a 8448-byte private header followed by a FIT whose header declares
totalsize = 0x1000, then the payload:

    offset            content
    0x0000..0x2100    private header  (copied verbatim from the vendor image)
    0x2100            FIT metadata    (totalsize field MUST say 0x1000)
    0x3100 + off      payload         (payload base = 0x2100 + 0x1000)

    total_size = *(le32)(img + 0xA0) + *(le32)(img + 0x98)

Verified by rebuilding the vendor KernelA from its own parts and comparing:
byte-for-byte identical (see docs/hg5580a-vendor-kernel-format.md).

Usage:
    mkvendor-kernel.py --header  <vendor-KernelA.bin> \
                       --fit     <openwrt.itb> \
                       --part-size 0x600000 \
                       --out     <KernelB.bin>

Why the header must come from a real dump: it carries the X.509 blob and the
X.509/GUID material U-Boot may validate.  Building it from scratch would mean
reimplementing FiberHome's signing scheme, which we cannot do without their
private key.
"""
import argparse
import hashlib
import os
import struct
import sys
import zlib

FDT_MAGIC = b'\xd0\x0d\xfe\xed'
HDR_END = 0x2100          # private header length in the vendor image
FIT_AREA = 0x1000         # reserved FIT metadata area, also the declared totalsize


def fatal(msg):
    sys.stderr.write(f"mkvendor-kernel: {msg}\n")
    sys.exit(1)


# --------------------------------------------------------------------------
# FDT parsing
# --------------------------------------------------------------------------
def fdt_header(d, base):
    if d[base:base + 4] != FDT_MAGIC:
        return None
    w = struct.unpack('>10I', d[base:base + 40])
    return {
        'total': w[1], 'off_struct': w[2], 'off_strings': w[3],
        'off_rsv': w[4], 'version': w[5], 'last_comp': w[6],
        'cpuid': w[7], 'sz_strings': w[8], 'sz_struct': w[9],
    }


def fit_subimages(d):
    """Return {name: {prop: bytes}} for images under /images."""
    h = fdt_header(d, 0)
    if not h:
        fatal("input is not a FIT (no d00dfeed magic at offset 0)")
    if h['total'] > len(d):
        fatal(f"FIT totalsize 0x{h['total']:x} exceeds file length {len(d):,}")

    sbuf = d[h['off_strings']:h['off_strings'] + h['sz_strings']]

    def s_at(i):
        e = sbuf.find(b'\0', i)
        return sbuf[i:e if e >= 0 else len(sbuf)].decode('latin1')

    p = h['off_struct']
    end = p + h['sz_struct']
    stack = []
    cur = None
    info = {}
    while p + 4 <= end:
        tok = struct.unpack('>I', d[p:p + 4])[0]
        p += 4
        if tok == 1:                                   # BEGIN_NODE
            z = d.find(b'\0', p)
            nm = d[p:z].decode('latin1')
            p = (z + 4) & ~3
            stack.append(nm)
            if len(stack) == 3 and stack[1] == 'images':
                cur = (nm, None)
                info.setdefault(nm, {})
        elif tok == 2:                                 # END_NODE
            if stack:
                stack.pop()
            cur = None
            if len(stack) >= 3 and stack[1] == 'images':
                cur = (stack[2], None) if len(stack) == 3 else None
        elif tok == 3:                                 # PROP
            ln, no = struct.unpack('>II', d[p:p + 8])
            p += 8
            val = d[p:p + ln]
            p = (p + ln + 3) & ~3
            if cur:
                img, sub = cur
                key = s_at(no) if sub is None else f'{sub}/{s_at(no)}'
                info.setdefault(img, {})[key] = val
        elif tok == 9:                                 # END
            break
    return h, info


def fdt_u32(props, key, default=None):
    v = props.get(key)
    if v is None or len(v) != 4:
        return default
    return struct.unpack('>I', v)[0]


# --------------------------------------------------------------------------
# FDT construction
# --------------------------------------------------------------------------
def build_fit(kernel, dt, comp, load, declared=FIT_AREA):
    """Build FIT metadata sized exactly `declared` bytes.

    Uses a declarative tree instead of hand-paired begin/end calls: the earlier
    version silently mis-nested /configurations inside /images because a missing
    FDT_END_NODE shifts every following sibling.
    """
    import io
    sblk = io.BytesIO()
    tblk = io.BytesIO()
    offsets = {}

    def s_add(s):
        if s not in offsets:
            offsets[s] = tblk.tell()
            tblk.write(s.encode() + b'\0')
        return offsets[s]

    def be32(v):
        return struct.pack('>I', v)

    dt_off = 0
    k_off = (len(dt) + 0xFFF) & ~0xFFF
    k_sha1 = hashlib.sha1(kernel).digest()

    tree = {
        'name': '',
        'props': [
            ('timestamp', be32(0x69766c30)),
            ('description', b'PonWrt kernel for FiberHome HG5580A\0'),
            ('#address-cells', be32(1)),
        ],
        'children': [
            {'name': 'images', 'props': [], 'children': [
                {'name': 'fdt-1', 'props': [
                    ('data-size', be32(len(dt))),
                    ('data-offset', be32(dt_off)),
                    ('description', b'PonWrt HG5580A device tree\0'),
                    ('type', b'flat_dt\0'),
                    ('arch', b'arm64\0'),
                    ('compression', b'none\0'),
                ], 'children': []},
                {'name': 'kernel', 'props': [
                    ('data-size', be32(len(kernel))),
                    ('data-offset', be32(k_off)),
                    ('description', b'PonWrt Linux kernel\0'),
                    ('type', b'kernel\0'),
                    ('arch', b'arm64\0'),
                    ('os', b'linux\0'),
                    ('compression', comp.encode() + b'\0'),
                    ('load', be32(load)),
                    ('entry', be32(load)),
                ], 'children': [
                    {'name': 'hash-1', 'props': [
                        ('value', k_sha1),
                        ('algo', b'sha1\0'),
                    ], 'children': []},
                ]},
            ]},
            {'name': 'configurations', 'props': [('default', b'conf-1\0')],
             'children': [
                 {'name': 'conf-1', 'props': [
                     ('description', b'Boot PonWrt kernel with FDT blob\0'),
                     ('fdt', b'fdt-1\0'),
                     ('kernel', b'kernel\0'),
                 ], 'children': []},
             ]},
        ],
    }

    def emit(node):
        sblk.write(be32(1))                     # FDT_BEGIN_NODE
        sblk.write(node['name'].encode() + b'\0')
        while sblk.tell() % 4:
            sblk.write(b'\0')
        for k, v in node['props']:
            sblk.write(struct.pack('>III', 3, len(v), s_add(k)))
            sblk.write(v)
            while sblk.tell() % 4:
                sblk.write(b'\0')
        for c in node['children']:
            emit(c)
        sblk.write(be32(2))                     # FDT_END_NODE

    emit(tree)
    sblk.write(be32(9))                         # FDT_END

    sdata = sblk.getvalue()
    tdata = tblk.getvalue()
    off_rsv = 40
    off_struct = off_rsv + 16
    off_strings = off_struct + len(sdata)
    used = off_strings + len(tdata)
    if used > declared:
        fatal(f"FIT metadata needs {used:,} B but the vendor area is {declared:,} B")

    hdr = struct.pack('>10I', 0xd00dfeed, declared, off_struct, off_strings,
                      off_rsv, 17, 16, 0, len(tdata), len(sdata))
    blob = hdr + b'\0' * 16 + sdata + tdata
    blob += b'\0' * (declared - len(blob))

    layout = {'dt_off': dt_off, 'kernel_off': k_off, 'sha1': k_sha1.hex(),
              'payload_len': k_off + len(kernel)}
    return blob, layout


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--header', required=True,
                    help='vendor KernelA/KernelB dump, used for the private header')
    ap.add_argument('--fit', required=True, help='OpenWrt .itb to wrap')
    ap.add_argument('--part-size', default='0x600000',
                    help='KernelX partition size (default 0x600000)')
    ap.add_argument('--out', required=True, help='output image')
    ap.add_argument('--quiet', action='store_true')
    a = ap.parse_args()

    part = int(a.part_size, 0)
    say = (lambda *x: None) if a.quiet else print

    vendor = open(a.header, 'rb').read()
    if len(vendor) < HDR_END:
        fatal(f"header file {len(vendor):,} B is shorter than {HDR_END}")

    fit = open(a.fit, 'rb').read()
    h, images = fit_subimages(fit)

    kname = 'kernel-1' if 'kernel-1' in images else 'kernel'
    fname = 'fdt-1' if 'fdt-1' in images else 'fdt'
    if kname not in images or fname not in images:
        fatal(f"FIT has no kernel/dt subimage; found {sorted(images)}")

    kernel = images[kname].get('data')
    dt = images[fname].get('data')
    if not kernel or not dt:
        fatal("kernel or device tree data missing from the FIT "
              "(is this an external-data FIT?)")

    comp = images[kname].get('compression', b'none').rstrip(b'\0').decode()
    load = fdt_u32(images[kname], 'load', 0x80200000)

    # Fail early with an actionable message: the initramfs FIT embeds the whole
    # root filesystem in the kernel, so it never fits KernelX.  Only the
    # sysupgrade FIT's kernel belongs in this partition.
    extent = HDR_END + FIT_AREA + ((len(dt) + 0xFFF) & ~0xFFF) + len(kernel)
    if extent > part:
        fatal(
            f"kernel subimage is {len(kernel):,} B ({comp}); the wrapped image "
            f"would be {extent:,} B but KernelX is only {part:,} B.\n"
            f"  Use the SYSUPGRADE fit, not the initramfs one: the initramfs "
            f"kernel carries the whole rootfs inside itself."
        )

    say(f"input FIT     : {a.fit}")
    say(f"  kernel      : {len(kernel):,} B  ({comp}, load 0x{load:08x})")
    say(f"  device tree : {len(dt):,} B")

    fit_area, layout = build_fit(kernel, dt, comp, load)
    say(f"  FIT meta    : {FIT_AREA:,} B declared, "
        f"{layout['payload_len'] + FIT_AREA + HDR_END:,} B total payload extent")

    img = bytearray(vendor[:HDR_END]) + bytearray(fit_area)
    img += dt
    img += b'\0' * (layout['kernel_off'] - len(dt))
    img += kernel

    a0 = HDR_END + FIT_AREA + layout['payload_len']
    total = (a0 + 0xFFF) & ~0xFFF
    struct.pack_into('<I', img, 0x98, total - a0)
    struct.pack_into('<I', img, 0xA0, a0)

    if len(img) > part:
        fatal(f"wrapped kernel is {len(img):,} B, exceeds KernelX {part:,} B "
              f"-- the kernel subimage is too large for this slot")

    img += b'\0' * (part - len(img))

    with open(a.out, 'wb') as fh:
        fh.write(img)

    say("")
    say(f"output        : {a.out}")
    say(f"  size        : {len(img):,} B (partition {part:,})")
    say(f"  0x98 pad    : 0x{total - a0:08x}")
    say(f"  0xA0 offset : 0x{a0:08x}")
    say(f"  total_size  : 0x{total:08x}")
    say(f"  kernel sha1 : {layout['sha1']}")
    say(f"  crc32       : 0x{zlib.crc32(img) & 0xffffffff:08x}")
    say(f"  sha256      : {hashlib.sha256(img).hexdigest()}")


if __name__ == '__main__':
    main()
