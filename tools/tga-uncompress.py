#!/usr/bin/env python3
"""Rewrites a run-length-encoded 32-bit TGA (type 10, as macOS `sips` writes)
as an uncompressed one (type 2), the variant the WoW client reliably loads.
Usage: tools/tga-uncompress.py <file.tga>... (in place)"""
import sys

for path in sys.argv[1:]:
    data = open(path, 'rb').read()
    header = bytearray(data[:18])
    if header[2] == 2:
        continue
    assert header[2] == 10 and header[16] == 32, f'{path}: expected RLE 32-bit TGA'
    width, height = header[12] | header[13] << 8, header[14] | header[15] << 8
    pos = 18 + header[0]  # skip the image ID field
    out, need = bytearray(), width * height * 4
    while len(out) < need:
        packet = data[pos]
        pos += 1
        count = (packet & 0x7F) + 1
        if packet & 0x80:  # run: one pixel repeated
            out += data[pos:pos + 4] * count
            pos += 4
        else:  # raw: count literal pixels
            out += data[pos:pos + 4 * count]
            pos += 4 * count
    header[0] = 0
    header[2] = 2
    open(path, 'wb').write(bytes(header) + bytes(out))
    print(f'{path}: {width}x{height} uncompressed')
