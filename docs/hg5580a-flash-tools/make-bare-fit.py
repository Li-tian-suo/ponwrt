#!/usr/bin/env python3
"""Prepare a BARE FIT for KernelB, for the bootm-based flash strategy.

Why a bare FIT and not the vendor container:

    Vendor bootcmd = ldkernel ; bargsenv ; bootm
                     ^^^^^^^^ does X.509 content-signature verification and
                              hangs on an unsigned kernel (measured).

    So we bypass ldkernel entirely:
        bootcmd = 'mtd read KernelB 0x88000000 0x0 0x600000; bootm 0x88000000'

    bootm only checks the hashes inside the FIT, which we generate ourselves.
    That means KernelB must hold a plain FIT at offset 0, not the wrapped form.

Memory check for bootm at 0x88000000:
    sysupgrade kernel: 5,905,664 B gzip -> 13,762,568 B decompressed
    decompress target: 0x80200000 .. 0x80200000 + 0x0D1E000 = 0x80F1E000
    0x80F1E000 < 0x88000000, so the FIT cannot be overwritten.
    (This is exactly why the initramfs FIT failed at 0x82000000: its kernel is
     33.9 MiB decompressed and ran past 0x82000000.)
"""
import struct
import hashlib
import zlib
import os
import sys

SRC = r'H:\Deepseek\hg5580a-port\backup\fw\built\ponwrt-airoha-an7583-fiberhome_hg5580a-squashfs-sysupgrade.bin'
OUT = r'H:\Deepseek\hg5580a-port\backup\fw\built\barefitB.bin'
PART = 0x600000
PAGE = 0x800


def main():
    d = open(SRC, 'rb').read()
    if d[:4] != b'\xd0\x0d\xfe\xed':
        sys.exit("input is not a FIT")
    fit_len = struct.unpack('>I', d[4:8])[0]
    print("source     : %s" % os.path.basename(SRC))
    print("  total    : %d" % len(d))
    print("  FIT size : %d (0x%x)" % (fit_len, fit_len))

    if fit_len > PART:
        sys.exit("FIT larger than KernelX")

    fit = d[:fit_len]
    padded = (fit_len + PAGE - 1) & ~(PAGE - 1)
    out = fit + b'\x00' * (padded - fit_len)

    print("  padded   : %d (0x%x)  +%d zero bytes" % (padded, padded, padded - fit_len))
    print("  fits     : %d <= %d  %s" % (padded, PART, padded <= PART))

    with open(OUT, 'wb') as fh:
        fh.write(out)

    print()
    print("wrote %s" % OUT)
    print("  size   %d" % len(out))
    print("  crc32  0x%08x" % (zlib.crc32(out) & 0xffffffff))
    print("  sha256 %s" % hashlib.sha256(out).hexdigest())
    print()
    print("U-Boot commands after flashing this to KernelB:")
    print("  setenv bootcmd 'mtd read KernelB 0x88000000 0x0 0x600000; bootm 0x88000000'")
    print("  saveenv")
    print()
    print("And bootargs must point at RootfsB:")
    print("  setenv bootargs 'console=ttyS0,115200 earlycon swiotlb=noforce "
          "root=/dev/mtdblock5 rootfstype=squashfs rootwait'")
    print("  saveenv")


if __name__ == '__main__':
    main()
