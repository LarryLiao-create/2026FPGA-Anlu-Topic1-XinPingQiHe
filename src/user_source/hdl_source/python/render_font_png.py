# -*- coding: utf-8 -*-
"""
render_font_png.py —— 把 char_rom 的 .hex 字库渲染成 PNG，用于人工核对字形。

用法:
    python render_font_png.py <font.hex> <out.png> [scale] [cols]

只依赖标准库（zlib）手写 PNG，避免安装第三方库。
输出为灰度 PNG：白底、黑字，每字放大 scale 倍，按 cols 列排布。
"""

import sys
import zlib
import struct

CELL = 16


def read_hex_rows(path):
    rows = []
    with open(path, "r", encoding="ascii") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            rows.append(int(s, 16))
    return rows


def png_chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data +
            struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def write_gray_png(path, w, h, get_px):
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter type 0
        for x in range(w):
            raw.append(get_px(x, y) & 0xFF)
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0)
    idat = zlib.compress(bytes(raw), 9)
    with open(path, "wb") as f:
        f.write(sig)
        f.write(png_chunk(b"IHDR", ihdr))
        f.write(png_chunk(b"IDAT", idat))
        f.write(png_chunk(b"IEND", b""))


def main():
    hex_path = sys.argv[1]
    out_png = sys.argv[2]
    scale = int(sys.argv[3]) if len(sys.argv) > 3 else 8
    cols = int(sys.argv[4]) if len(sys.argv) > 4 else 5

    rows = read_hex_rows(hex_path)
    n_chars = len(rows) // CELL
    n_rows = (n_chars + cols - 1) // cols

    cell = CELL * scale
    gap = scale  # 字间距
    W = cols * (cell + gap) + gap
    H = n_rows * (cell + gap) + gap

    # 预先把每个字形的 16x16 位图铺开成像素表
    def px(x, y):
        gx = x - gap
        gy = y - gap
        c = gx // (cell + gap)
        r = gy // (cell + gap)
        if c < 0 or c >= cols or r < 0 or r >= n_rows or c >= n_chars:
            return 255
        ox = gx % (cell + gap)
        oy = gy % (cell + gap)
        if ox >= cell or oy >= cell:
            return 200  # 边框灰
        lx = ox // scale
        ly = oy // scale
        idx = r * cols + c
        word = rows[idx * CELL + ly]
        bit = (word >> (CELL - 1 - lx)) & 1
        return 0 if bit else 255

    write_gray_png(out_png, W, H, px)

    print("ok chars=%d grid=%dx%d png=%dx%d -> %s" % (n_chars, cols, n_rows, W, H, out_png))


if __name__ == "__main__":
    main()
