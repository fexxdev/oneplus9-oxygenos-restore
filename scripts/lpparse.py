import struct, sys
data=open(sys.argv[1],'rb').read()
def s(b): return b.split(b'\0',1)[0].decode(errors='replace')
# geometry at 4096
g=data[4096:4096+4096]
gmagic,gsize=struct.unpack_from('<II',g,0)
md_max,slots,lbs=struct.unpack_from('<III',g,8+32)
print(f"geometry: magic={gmagic:#x} ok={gmagic==0x616c4467} metadata_max_size={md_max} slots={slots} block={lbs}")
for slot in range(slots):
    off=4096+2*4096+md_max*slot
    h=data[off:off+md_max]
    magic,major,minor,hsize=struct.unpack_from('<IHHI',h,0)
    print(f"\n=== metadata slot {slot} @ {off}: magic={magic:#x} ok={magic==0x414C5030} version={major}.{minor} header_size={hsize}")
    if magic!=0x414C5030: continue
    tables_size=struct.unpack_from('<I',h,12+32)[0]
    # tables descriptors start at 12+32+4+32 = 80
    p_off,p_n,p_sz=struct.unpack_from('<III',h,80)
    e_off,e_n,e_sz=struct.unpack_from('<III',h,92)
    g_off,g_n,g_sz=struct.unpack_from('<III',h,104)
    b_off,b_n,b_sz=struct.unpack_from('<III',h,116)
    flags=struct.unpack_from('<I',h,128)[0] if hsize>128 else None
    print(f"flags={flags} partitions={p_n} extents={e_n} groups={g_n} blockdevs={b_n}")
    T=hsize
    groups=[]
    for i in range(g_n):
        o=T+g_off+i*g_sz; name=s(h[o:o+36]); gf,mx=struct.unpack_from('<IQ',h,o+36); groups.append(name); print(f"  group[{i}] {name} flags={gf} max={mx}")
    for i in range(b_n):
        o=T+b_off+i*b_sz; fls,al,alo,sz=struct.unpack_from('<QIIQ',h,o); name=s(h[o+24:o+60]); bf=struct.unpack_from('<I',h,o+60)[0]
        print(f"  blockdev[{i}] {name} size={sz} ({sz>>20} MB) first_sector={fls} align={al} flags={bf}")
    exts=[]
    for i in range(e_n):
        o=T+e_off+i*e_sz; ns,tt,td,ts=struct.unpack_from('<QIQI',h,o); exts.append((ns,tt,td,ts))
    total=0
    for i in range(p_n):
        o=T+p_off+i*p_sz; name=s(h[o:o+36]); attr,fe,ne,gi=struct.unpack_from('<IIII',h,o+36)
        pe=exts[fe:fe+ne]; size=sum(e[0] for e in pe)*512; total+=size
        print(f"  {name:20s} attr={attr:#04x} group={groups[gi] if gi<len(groups) else gi} size={size} ({size/1048576:.1f} MB) extents={[(e[2],e[0]) for e in pe]}")
    print(f"  TOTAL allocated: {total/1048576:.0f} MB")
