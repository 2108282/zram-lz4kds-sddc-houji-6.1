import sys, struct

from stock_crc_dict import STOCK_CRCS

ko_path = sys.argv[1]
with open(ko_path, 'rb') as f:
    data = bytearray(f.read())

# Parse ELF64 header
e_shoff, = struct.unpack('<Q', data[40:48])
e_shentsize, = struct.unpack('<H', data[58:60])
e_shnum, = struct.unpack('<H', data[60:62])
e_shstrndx, = struct.unpack('<H', data[62:64])

# Read shstrtab
shstr_offset = e_shoff + e_shstrndx * e_shentsize
sh_offset, = struct.unpack('<Q', data[shstr_offset+24:shstr_offset+32])
sh_size, = struct.unpack('<Q', data[shstr_offset+32:shstr_offset+40])
shstrtab = data[sh_offset:sh_offset+sh_size]

offset = 0
size = 0
for i in range(e_shnum):
    sec = e_shoff + i * e_shentsize
    sh_name, = struct.unpack('<I', data[sec:sec+4])
    name = shstrtab[sh_name:].split(b'\x00')[0].decode('latin1')
    if name == '__versions':
        offset, = struct.unpack('<Q', data[sec+24:sec+32])
        size, = struct.unpack('<Q', data[sec+32:sec+40])
        break

print(f"Located __versions at offset {hex(offset)}, size {hex(size)}")
assert offset > 0 and size > 0

patched = 0
for p in range(offset, offset + size, 64):
    chunk = data[p:p+64]
    name = bytes(chunk[8:]).split(b'\x00')[0].decode('latin1', errors='ignore')
    if name in STOCK_CRCS:
        old_crc, = struct.unpack('<Q', chunk[:8])
        new_crc = STOCK_CRCS[name]
        if old_crc != new_crc:
            struct.pack_into('<Q', data, p, new_crc)
            print(f"  Patched CRC for {name}: {hex(old_crc)} -> {hex(new_crc)}")
            patched += 1

with open(ko_path, 'wb') as f:
    f.write(data)

print(f"Successfully patched {patched} symbols in {ko_path} to exact stock CRCs!")
