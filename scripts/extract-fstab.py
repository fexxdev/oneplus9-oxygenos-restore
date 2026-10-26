#!/usr/bin/env python3
"""Print the first-stage fstab files embedded in a vendor_boot.img (v3/v4 header,
gzip or lz4 vendor ramdisk). Useful to learn which partitions init requires.

Usage: extract-fstab.py <vendor_boot.img>
"""
import struct, sys, io, gzip, subprocess, tempfile, os
d = open(sys.argv[1], 'rb').read()
assert d[:8] == b'VNDRBOOT', 'not a vendor_boot image'
hv, ps, ka, ra, rs = struct.unpack_from('<IIIII', d, 8)
hs = struct.unpack_from('<I', d, 2096)[0]
o = (hs + ps - 1) // ps * ps
rd = d[o:o + rs]
if rd[:2] == b'\x1f\x8b':
    raw = gzip.decompress(rd)
elif rd[:4] in (b'\x02\x21\x4c\x18', b'\x04\x22\x4d\x18'):
    raw = subprocess.run(['lz4', '-dc'], input=rd, capture_output=True, check=True).stdout
else:
    raise SystemExit('unknown ramdisk compression %s' % rd[:4].hex())
with tempfile.TemporaryDirectory() as t:
    subprocess.run(['cpio', '-idm', '--no-absolute-filenames', '--quiet'], input=raw, cwd=t, check=False, capture_output=True)
    for root, _, files in os.walk(t):
        for f in files:
            if 'fstab' in f:
                p = os.path.join(root, f)
                print('=====', os.path.relpath(p, t))
                for line in open(p, errors='replace'):
                    if line.strip() and not line.startswith('#'):
                        c = line.split()
                        print(f"{c[0]:45s} {c[1]:26s} {c[2]:6s} {c[4] if len(c)>4 else ''}")
