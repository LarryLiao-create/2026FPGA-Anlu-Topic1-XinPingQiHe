# -*- coding: utf-8 -*-
"""
gen_font16.py —— 从 Windows 宋体 simsun.ttc 提取 16x16 汉字点阵，生成 FPGA char_rom 字库数据。

用途：
    为 HDL 模块 char_rom 生成 16x16 点阵字库（.hex），并提供 ASCII 预览用于人工核对字形。

输入：
    simsun.ttc 中内嵌的 EBDT/EBLC 位图（ppem=16, bitDepth=1），无需外部字库文件。

输出：
    argv[1] 指向的 .hex 文件：320 行，每行 4 个十六进制字符（16bit 一行点阵）。
        行序 = 字符位置 0..19（按 TEXT 顺序） × 每字 16 行。
        字内位序：bit15 = 字符格最左列(x=local 0)，bit0 = 最右列(x=local 15)。
    argv[2] 指向的 .txt 文件：逐字 ASCII 预览（'#'=墨点，'.'=空）。

用法：
    python gen_font16.py <out.hex> <out_preview.txt>
"""

import struct
import sys
import os

# 字幕文本：18 个汉字 + 2 个全角标点，共 20 个字符格
TEXT = "温馨提示：请保持安静，有序就诊，谢谢配合"

FONT_PATH = r"C:\Windows\Fonts\simsun.ttc"
CELL = 16  # 字符格 16x16

# 点阵字号
TARGET_PPEM = 16


# ---------------------------------------------------------------------------
# 1. 打开 TTC，取出第一个字体的表目录
# ---------------------------------------------------------------------------
def open_sfnt(path):
    d = open(path, "rb").read()
    tag = d[:4]
    if tag == b"ttcf":
        num = struct.unpack(">I", d[8:12])[0]
        offs = struct.unpack(">%dI" % num, d[12:12 + 4 * num])
        off = offs[0]
    else:
        off = 0
    num_tables = struct.unpack(">H", d[off + 4:off + 6])[0]
    tables = {}
    for i in range(num_tables):
        r = off + 12 + 16 * i
        t, _cs, o, l = struct.unpack(">4sIII", d[r:r + 16])
        tables[t.decode("latin1")] = (o, l)
    return d, tables


# ---------------------------------------------------------------------------
# 2. cmap：Unicode 码点 -> 字形 id
# ---------------------------------------------------------------------------
def parse_cmap(d, tables):
    co, _cl = tables["cmap"]
    _ver, num = struct.unpack(">HH", d[co:co + 4])
    chosen = None
    # 优先级：3/10 (UCS-4) > 0/4 > 3/1 (BMP) > 0/3
    for want in [(3, 10), (0, 4), (0, 6), (3, 1), (0, 3), (0, 2), (0, 1), (0, 0)]:
        for i in range(num):
            p, e, so = struct.unpack(">HHI", d[co + 4 + 8 * i:co + 12 + 8 * i])
            if (p, e) == want:
                chosen = co + so
                break
        if chosen:
            break
    if chosen is None:
        raise RuntimeError("no usable cmap subtable")

    fmt = struct.unpack(">H", d[chosen:chosen + 2])[0]
    cmap = {}
    if fmt == 4:
        seg_x2 = struct.unpack(">H", d[chosen + 6:chosen + 8])[0]
        seg = seg_x2 // 2
        endo = chosen + 14
        starto = endo + seg_x2 + 2
        deltao = starto + seg_x2
        rangeo = deltao + seg_x2
        for s in range(seg):
            end = struct.unpack(">H", d[endo + 2 * s:endo + 2 * s + 2])[0]
            st = struct.unpack(">H", d[starto + 2 * s:starto + 2 * s + 2])[0]
            delta = struct.unpack(">h", d[deltao + 2 * s:deltao + 2 * s + 2])[0]
            ro = struct.unpack(">H", d[rangeo + 2 * s:rangeo + 2 * s + 2])[0]
            if st == 0xFFFF:
                continue
            for c in range(st, min(end, 0xFFFE) + 1):
                if ro == 0:
                    g = (c + delta) & 0xFFFF
                else:
                    gi = rangeo + 2 * s + ro + 2 * (c - st)
                    g = struct.unpack(">H", d[gi:gi + 2])[0]
                    if g:
                        g = (g + delta) & 0xFFFF
                if g:
                    cmap[c] = g
    elif fmt == 12:
        ngroups = struct.unpack(">I", d[chosen + 12:chosen + 16])[0]
        for i in range(ngroups):
            s, e, sg = struct.unpack(">III", d[chosen + 16 + 12 * i:chosen + 28 + 12 * i])
            for c in range(s, e + 1):
                cmap[c] = sg + (c - s)
    elif fmt == 6:
        first, count = struct.unpack(">HH", d[chosen + 6:chosen + 10])
        for i in range(count):
            g = struct.unpack(">H", d[chosen + 10 + 2 * i:chosen + 12 + 2 * i])[0]
            if g:
                cmap[first + i] = g
    else:
        raise RuntimeError("unsupported cmap format %d" % fmt)
    return cmap, fmt


# ---------------------------------------------------------------------------
# 3. EBLC：定位 ppem=16 的位图 strike，并取出索引子表
# ---------------------------------------------------------------------------
def find_strike(d, tables, ppem):
    eo, _el = tables["EBLC"]
    ebdt_off, _edl = tables["EBDT"]
    _ver, num_sizes = struct.unpack(">II", d[eo:eo + 8])
    for s in range(num_sizes):
        b = eo + 8 + 48 * s
        px, py = struct.unpack(">BB", d[b + 44:b + 46])
        if px == ppem and py == ppem:
            isa_off, its_size, num_ist, _cr = struct.unpack(">IIII", d[b:b + 16])
            # indexSubTableArrayOffset 相对 EBLC 表起点
            return eo + isa_off, ebdt_off, num_ist
    raise RuntimeError("no %dppem strike" % ppem)


def image_subtable_for_gid(d, isa_abs, ebdt_off, num_ist, gid):
    for k in range(num_ist):
        r = isa_abs + 8 * k
        f, l, add = struct.unpack(">HHI", d[r:r + 8])
        if not (f <= gid <= l):
            continue
        ist = isa_abs + add
        ifmt, imfmt, ido = struct.unpack(">HHI", d[ist:ist + 8])
        n = l - f + 2
        if ifmt == 1:
            arr = struct.unpack(">%dI" % n, d[ist + 8:ist + 8 + 4 * n])
        elif ifmt == 3:
            arr = struct.unpack(">%dH" % n, d[ist + 8:ist + 8 + 2 * n])
        else:
            return None
        g0 = arr[gid - f]
        # imageDataOffset 相对 EBDT 表起点
        return ebdt_off + ido + g0, imfmt
    return None


# ---------------------------------------------------------------------------
# 4. EBDT：取出单个字形的位图
# ---------------------------------------------------------------------------
def get_glyph_bitmap(d, isa_abs, ebdt_off, num_ist, gid):
    r = image_subtable_for_gid(d, isa_abs, ebdt_off, num_ist, gid)
    if r is None:
        return None
    gb, imfmt = r
    p = gb
    h = w = bx = by = 0
    if imfmt in (1, 2):
        h, w, bx, by, _adv = struct.unpack(">BBbbb", d[p:p + 5])
        p += 5
    elif imfmt in (5, 6, 7):
        _sz = d[p]
        h, w, bx, by, _adv = struct.unpack(">BBbbb", d[p + 1:p + 6])
        p += 8
    else:
        return None

    rows = []
    if imfmt in (1, 6) and (w % 8 == 0):
        # 字节对齐
        stride = (w + 7) // 8
        for y in range(h):
            bits = []
            for x in range(w):
                byte = d[p + y * stride + x // 8]
                bits.append((byte >> (7 - (x % 8))) & 1)
            rows.append(bits)
    elif imfmt in (1, 2, 5, 6, 7):
        # 位紧凑
        total = w * h
        bitdata = d[p:p + (total + 7) // 8]
        flat = []
        for i in range(total):
            flat.append((bitdata[i // 8] >> (7 - (i % 8))) & 1)
        rows = [flat[y * w:(y + 1) * w] for y in range(h)]
    else:
        return None
    return h, w, bx, by, imfmt, rows


# ---------------------------------------------------------------------------
# 5. 把字形摆进 16x16 字符格
# ---------------------------------------------------------------------------
def place_in_cell(h, w, bx, by, rows):
    """CJK 字形基本满格且无下伸部，按底部对齐、水平用 bearingX 摆放。"""
    cell = [[0] * CELL for _ in range(CELL)]
    row_off = CELL - h                      # 底对齐
    col_off = bx if bx >= 0 else 0
    for y in range(h):
        ty = row_off + y
        if not (0 <= ty < CELL):
            continue
        for x in range(w):
            tx = col_off + x
            if not (0 <= tx < CELL):
                continue
            if rows[y][x]:
                cell[ty][tx] = 1
    return cell


def cell_to_word16(row_bits):
    w = 0
    for x in range(CELL):
        if row_bits[x]:
            w |= (1 << (CELL - 1 - x))
    return w


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main():
    out_hex = sys.argv[1] if len(sys.argv) > 1 else "font16_20x16.hex"
    out_prev = sys.argv[2] if len(sys.argv) > 2 else "font16_preview.txt"

    if not os.path.exists(FONT_PATH):
        raise SystemExit("font not found: %s" % FONT_PATH)

    d, tables = open_sfnt(FONT_PATH)
    for need in ("cmap", "EBLC", "EBDT"):
        if need not in tables:
            raise SystemExit("font lacks table %s" % need)

    cmap, cmap_fmt = parse_cmap(d, tables)
    isa_abs, ebdt_off, num_ist = find_strike(d, tables, TARGET_PPEM)

    words = []          # 320 个 16bit 行
    prev_lines = []
    prev_lines.append("simsun.ttc  EBDT %dppem  cmap fmt=%d" % (TARGET_PPEM, cmap_fmt))
    prev_lines.append("文本: %s   (字符格数=%d)" % (TEXT, len(TEXT)))
    prev_lines.append("")

    missing = []
    for idx, ch in enumerate(TEXT):
        cp = ord(ch)
        gid = cmap.get(cp)
        prev_lines.append("[%2d] '%s'  U+%04X  gid=%s" % (idx, ch, cp, gid))
        cell = [[0] * CELL for _ in range(CELL)]
        if gid is not None:
            g = get_glyph_bitmap(d, isa_abs, ebdt_off, num_ist, gid)
            if g is not None:
                h, w, bx, by, imfmt, rows = g
                prev_lines.append("      h=%d w=%d bx=%d by=%d imfmt=%d" % (h, w, bx, by, imfmt))
                cell = place_in_cell(h, w, bx, by, rows)
            else:
                prev_lines.append("      <no bitmap data>")
                missing.append((idx, ch, "nobitmap"))
        else:
            prev_lines.append("      <no glyph in cmap>")
            missing.append((idx, ch, "nogid"))
        for y in range(CELL):
            prev_lines.append("      " + "".join("#" if v else "." for v in cell[y]))
        for y in range(CELL):
            words.append(cell_to_word16(cell[y]))
        prev_lines.append("")

    # 写 hex
    with open(out_hex, "w", encoding="ascii", newline="\n") as f:
        for w in words:
            f.write("%04X\n" % (w & 0xFFFF))

    # 写预览
    os.makedirs(os.path.dirname(os.path.abspath(out_prev)), exist_ok=True)
    with open(out_prev, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(prev_lines) + "\n")

    # 终端摘要（ASCII 安全）
    print("font extraction done")
    print("  chars=%d  words=%d  (expect %d)" % (len(TEXT), len(words), len(TEXT) * CELL))
    print("  hex  -> %s" % out_hex)
    print("  prev -> %s" % out_prev)
    if missing:
        print("  MISSING: %s" % missing)
    else:
        print("  all glyphs extracted OK")
    nonblank = sum(1 for w in words if w != 0)
    print("  non-blank rows = %d / %d" % (nonblank, len(words)))


if __name__ == "__main__":
    main()
