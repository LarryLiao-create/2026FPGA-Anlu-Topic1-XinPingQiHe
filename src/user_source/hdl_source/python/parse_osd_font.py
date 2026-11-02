# -*- coding: utf-8 -*-
"""
parse_osd_font.py —— 解析用户提供的 osd.TXT 字模数据，合并成 16 位字模，输出 .hex。

输入格式（doc/osd/osd_font21_src.txt 中的 { ... } 数据块）：
    每字 32 字节，每行 2 字节；高字节在前。
    合并：{0x08,0x20} -> 16'h0820（bit15 = 字符格最左列）。

输出：argv[1] 指定的 .hex，每行 4 位十六进制，行数 = 字符数 * 16。

用法：
    python parse_osd_font.py <src.txt> <out.hex>
"""

import re
import sys


def main():
    src = sys.argv[1]
    out = sys.argv[2]

    text = open(src, "r", encoding="utf-8").read()

    # 去掉 '# ...' 注释行，避免误解析
    lines = [ln for ln in text.splitlines() if not ln.lstrip().startswith("#")]
    body = "\n".join(lines)

    # 收集所有 { ... } 块中的十六进制字节
    blocks = re.findall(r"\{([^{}]*)\}", body)
    data = []
    for b in blocks:
        for tok in b.split(","):
            tok = tok.strip()
            if not tok:
                continue
            if not re.fullmatch(r"0[xX][0-9A-Fa-f]{1,2}", tok):
                raise SystemExit("bad token: %r" % tok)
            data.append(int(tok, 16))

    if len(data) % 2 != 0:
        raise SystemExit("odd byte count: %d" % len(data))

    words = [(data[i] << 8) | data[i + 1] for i in range(0, len(data), 2)]

    print("bytes = %d" % len(data))
    print("words = %d" % len(words))
    if len(words) % 16 != 0:
        raise SystemExit("word count %d is not a multiple of 16" % len(words))
    print("chars = %d" % (len(words) // 16))

    with open(out, "w", encoding="ascii", newline="\n") as f:
        for w in words:
            f.write("%04X\n" % (w & 0xFFFF))

    # 自检：打印每字首行，便于人工比对
    n = len(words) // 16
    for c in range(n):
        head = " ".join("%04X" % words[c * 16 + r] for r in range(4))
        print("  char[%2d] head: %s" % (c, head))
    print("written -> %s" % out)


if __name__ == "__main__":
    main()
