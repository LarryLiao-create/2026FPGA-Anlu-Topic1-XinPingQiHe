#!/usr/bin/env python3
"""Cycle-accurate model of the rewritten bmp_scale.v.

Mirrors the RTL register structure 1:1 (same state machines, same pipeline
registers, same update rules) so that off-by-one / deadlock / alignment bugs
show up before the design goes to the FPGA.
"""
LINE_W = 640
DST_H = 480
NB = 4
QDEPTH = 16
WAIT_MAX = 16_000_000


def div(a, b):
    return a // b


class Scale:
    def __init__(self, src_w, src_h):
        self.src_w = src_w
        self.src_h = src_h
        sw480 = src_w * 480
        sh640 = src_h * 640
        if sw480 >= sh640:
            self.dst_w = 640
            self.x0 = 0
            self.x1 = 640
            dh = div(src_h * 640, src_w)
            self.dst_h = min(max(dh, 1), 480)
            self.top0 = (480 - self.dst_h) >> 1
        else:
            self.dst_h = 480
            self.top0 = 0
            dw = div(src_w * 480, src_h)
            self.dst_w = min(max(dw, 1), 640)
            self.x0 = (640 - self.dst_w) >> 1
            self.x1 = self.x0 + self.dst_w
        self.img_end = self.top0 + self.dst_h

        self.buf = [[None] * LINE_W for _ in range(NB)]
        self.bank_tag = [0] * NB
        self.bank_vld = [0] * NB

        # write side
        self.w_state = 'ROW'
        self.w_acc = 0
        self.w_pix = 0
        self.w_sx = 0
        self.w_ox = 0
        self.w_row = 0
        self.wr_lines = 0
        self.wr_en = 0
        self.wr_addr = 0
        self.wr_data = 0
        self.inq = [None] * QDEPTH
        self.wp = 0
        self.rp = 0
        self.cnt = 0
        self.lost = 0

        # read side
        self.r_state = 'WAIT'
        self.rd_line = 0
        self.out_row = 0
        self.v_acc = 0
        self.v_added = 0
        self.p = 0
        self.rd_sel = 0
        self.rd_row_ok = 0
        self.win_q = 0
        self.rd_data_r = 0
        self.r_blk = 0
        self.wait_cnt = 0
        self.force_black = 0
        self.done_r = 0
        self.out_valid = 0
        self.out_pixel = 0
        self.out = []

    def push(self, pix):
        if self.w_row >= self.src_h or self.cnt == QDEPTH:
            self.lost += 1
            return False
        self.inq[self.wp] = pix
        self.wp = (self.wp + 1) & (QDEPTH - 1)
        self.cnt += 1
        return True

    def cycle(self, out_ready):
        if self.wr_en:
            self.buf[self.w_row & 3][self.wr_addr] = self.wr_data

        rd_en = (self.r_state == 'LINE') and out_ready and (self.p <= LINE_W)
        in_win = (self.x0 <= self.p < self.x1) and (self.p < LINE_W)
        rd_off = (self.p - self.x0) if in_win else 0
        old_rd_data_r = self.rd_data_r
        if rd_en:
            self.rd_data_r = self.buf[self.rd_sel][rd_off]

        # ---------------- write FSM ----------------
        self.wr_en = 0
        ahead = (self.w_row - self.rd_line) & 0xFFFF
        bank_free = (self.w_row < self.rd_line) or (ahead <= 3)
        if self.w_state == 'ROW':
            if self.src_w != 0 and self.w_row < self.src_h and bank_free:
                self.w_pix = 0
                self.w_sx = 0
                self.w_ox = 0
                self.w_acc = 0
                self.bank_vld[self.w_row & 3] = 0
                self.w_state = 'GET'
        elif self.w_state == 'GET':
            if self.cnt != 0:
                self.w_pix = self.inq[self.rp]
                self.rp = (self.rp + 1) & (QDEPTH - 1)
                self.cnt -= 1
                self.w_sx += 1
                self.w_acc += self.dst_w
                self.w_state = 'EMIT'
        elif self.w_state == 'EMIT':
            if self.w_acc >= self.src_w and self.w_ox < LINE_W:
                self.wr_en = 1
                self.wr_data = self.w_pix
                self.wr_addr = self.w_ox
                self.w_ox += 1
                self.w_acc -= self.src_w
            elif self.w_sx >= self.src_w:
                self.w_state = 'PAD'
            else:
                self.w_state = 'GET'
        elif self.w_state == 'PAD':
            if self.w_ox < LINE_W:
                self.wr_en = 1
                self.wr_data = 0
                self.wr_addr = self.w_ox
                self.w_ox += 1
            else:
                self.w_state = 'PUB'
        elif self.w_state == 'PUB':
            self.bank_tag[self.w_row & 3] = self.w_row
            self.bank_vld[self.w_row & 3] = 1
            self.wr_lines += 1
            self.w_row += 1
            self.w_state = 'ROW'

        # ---------------- read FSM ----------------
        if self.r_state == 'WAIT':
            self.out_valid = 0
            self.out_pixel = 0
            if self.out_row >= DST_H:
                self.r_state = 'DONE'
            elif (self.force_black or self.out_row < self.top0
                  or self.out_row >= self.img_end):
                self.r_blk = 0
                self.r_state = 'BLACK'
            elif self.rd_line >= self.src_h:
                self.force_black = 1
            elif (self.bank_vld[self.rd_line & 3] and
                  self.bank_tag[self.rd_line & 3] == self.rd_line):
                self.rd_sel = self.rd_line & 3
                self.rd_row_ok = 1
                self.p = 0
                self.wait_cnt = 0
                self.r_state = 'LINE'
            elif self.wr_lines >= self.src_h:
                self.force_black = 1
            elif self.wait_cnt >= WAIT_MAX:
                self.force_black = 1
            else:
                self.wait_cnt += 1
        elif self.r_state == 'LINE':
            if out_ready:
                self.out_valid = 1 if (1 <= self.p <= LINE_W) else 0
                if 1 <= self.p <= LINE_W and self.rd_row_ok and self.win_q:
                    self.out_pixel = old_rd_data_r
                else:
                    self.out_pixel = 0
                self.win_q = 1 if in_win else 0
                if self.p == LINE_W + 1:
                    self.p = 0
                    self.r_state = 'VADV'
                else:
                    self.p += 1
        elif self.r_state == 'BLACK':
            if out_ready:
                if self.r_blk < LINE_W:
                    self.out_valid = 1
                    self.out_pixel = 0
                    self.r_blk += 1
                else:
                    self.out_valid = 0
                    self.out_pixel = 0
                    self.r_blk = 0
                    self.out_row += 1
                    self.r_state = 'WAIT'
        elif self.r_state == 'VADV':
            self.out_valid = 0
            if not self.v_added:
                self.v_acc += self.src_h
                self.v_added = 1
            elif self.v_acc >= self.dst_h:
                self.v_acc -= self.dst_h
                self.rd_line += 1
            else:
                self.v_added = 0
                self.out_row += 1
                self.r_state = 'WAIT'
        elif self.r_state == 'DONE':
            self.out_valid = 0
            self.done_r = 1

        if self.out_valid and out_ready:
            self.out.append(self.out_pixel)


def run(src_w, src_h, gap=12, bp_period=2000, bp_len=100):
    s = Scale(src_w, src_h)
    print(f"src={src_w}x{src_h} -> dst_w={s.dst_w} dst_h={s.dst_h} "
          f"x0={s.x0} x1={s.x1} top0={s.top0} gap={gap}")
    it = ((y, x) for y in range(src_h) for x in range(src_w))
    cur = next(it, None)
    nxt_at = 10
    t = 0
    while t < 200_000_000:
        t += 1
        if cur is not None and t == nxt_at:
            s.push((cur[0] << 11) | cur[1])
            cur = next(it, None)
            nxt_at = t + gap
        out_ready = 0 if (bp_period and (t % bp_period) < bp_len) else 1
        s.cycle(out_ready)
        if s.r_state == 'DONE' and len(s.out) > 0:
            break
    errs = 0
    exp_total = LINE_W * DST_H
    for i, px in enumerate(s.out):
        row, col = div(i, LINE_W), i % LINE_W
        exp = 0
        if s.top0 <= row < s.top0 + s.dst_h and s.x0 <= col < s.x1:
            er = div(row - s.top0, 1) * src_h // s.dst_h
            ec = div((col - s.x0 + 1) * src_w - 1, s.dst_w)
            exp = (er << 11) | ec
        if px != exp:
            if errs < 6:
                print(f"   MISMATCH i={i} row={row} col={col} "
                      f"got={px:06x} exp={exp:06x}")
            errs += 1
    print(f"   cycles={t} px_out={len(s.out)} (exp {exp_total}) "
          f"mismatch={errs} lost_in_pix={s.lost} wr_lines={s.wr_lines}")
    ok = (len(s.out) == exp_total and errs == 0 and s.lost == 0)
    print("   RESULT:", "PASS" if ok else "FAIL")
    return ok


if __name__ == "__main__":
    allok = True
    # gap 96 = real SD byte rate at 100 MHz core / 25 MHz SPI (1 pixel / 96 clk)
    # gap 6 is only used for 4:3 sources (no pad phase, no black bars -> the
    # writer is never throttled, so an accelerated input is still valid).
    cases = [(640, 480, 6), (800, 600, 6), (1024, 768, 6), (1920, 1080, 6),
             (320, 240, 96), (480, 270, 96), (240, 320, 48), (270, 480, 48),
             (100, 700, 96), (160, 100, 96)]
    for (w, h, gp) in cases:
        allok &= run(w, h, gap=gp)
    print("ALL:", "PASS" if allok else "FAIL")

