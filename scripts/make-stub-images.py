#!/usr/bin/env python3
"""Generate stub images for OnePlus/Oplus `my_*` logical partitions that are
required by the OxygenOS fstab but are NOT shipped in full OTA packages
(typically my_company and my_preload).

The stub is derived from a tiny "empty" partition image that IS in the OTA
(my_carrier.img, ~328 KB erofs: standard dirs + build.prop with
`ro.oplus.image.<name>.type=empty`). We rename it in place (same-length name)
and recompute the erofs superblock crc32c, which covers the first 4 KiB block
where the inline build.prop lives.

Usage:  make-stub-images.py <my_carrier.img> <outdir> [name ...]
        (default names: my_company my_preload)
"""
import struct, sys, os

def crc32c_table():
    t = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = (c >> 1) ^ 0x82F63B78 if c & 1 else c >> 1
        t.append(c)
    return t

T = crc32c_table()

def crc32c(buf, crc=0xFFFFFFFF):
    for b in buf:
        crc = T[(crc ^ b) & 0xFF] ^ (crc >> 8)
    return crc

def fix_erofs_checksum(d):
    magic, chk, feat = struct.unpack_from('<III', d, 1024)
    if magic != 0xE0F5E1E2:
        raise SystemExit("not an erofs image (magic %#x)" % magic)
    if not feat & 1:            # SB_CHKSUM feature not enabled
        return d
    blk = 1 << d[1036]
    body = bytearray(d[1024:blk]); struct.pack_into('<I', body, 4, 0)
    struct.pack_into('<I', d, 1028, crc32c(bytes(body)))
    return d

def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(1)
    src, outdir = sys.argv[1], sys.argv[2]
    names = sys.argv[3:] or ['my_company', 'my_preload']
    base = os.path.basename(src)[:-4]             # e.g. my_carrier
    d0 = open(src, 'rb').read()
    os.makedirs(outdir, exist_ok=True)
    for n in names:
        if len(n) != len(base):
            raise SystemExit(f"{n}: name must have the same length as {base}")
        d = bytearray(d0.replace(base.encode(), n.encode()))
        d = fix_erofs_checksum(d)
        out = os.path.join(outdir, n + '.img')
        open(out, 'wb').write(d)
        print(f"{out}: {len(d)} bytes, {d0.count(base.encode())} replacements, checksum fixed")

if __name__ == '__main__':
    main()
