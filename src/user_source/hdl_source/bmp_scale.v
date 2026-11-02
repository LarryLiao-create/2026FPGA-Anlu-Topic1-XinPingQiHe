`timescale 1ns / 1ps
//==========================================================================
//  bmp_scale : BMP 24bit 源像素流 -> 640x480 逐点采样缩放 + 保比例黑边
//
//  标准 Verilog-2001，无任何厂商专用原语（BRAM 由下面的双 always 模板
//  自动推断，不写 eg_logic_bram / RAM_0 之类）。
//
//  ---- 行缓存 ----
//      4 个 bank，每个 640 x 24bit。写侧把源行写进 bank[w_row[1:0]]，
//      640 列全部写满之后才在 W_PUB 状态发布（bank_tag / bank_vld）。
//
//  ---- 本文件围绕的关键不变式 ----
//   1) 写侧每行把 0..639 全部 640 列写一遍（真实像素 + 24'd0 补齐），
//      写满之后才置 bank_vld；读侧只有在 tag 命中的整行上才允许输出数据。
//   2) 读侧每个输出行严格产生 640 个 out_valid（R_LINE 642 拍出 640 个，
//      R_BLACK 640 拍出 640 个），一帧严格 480 行 = 307200 像素，与
//      frame_fifo_write 的 write_len / VFLIP 行计数严格对齐。
//   3) 输出像素 = (列在窗口内 && 本行是已发布行) ? BRAM 数据 : 24'd0。
//      窗口外 / 未初始化 / 行号不匹配一律强制 24'd0，绝不输出 BRAM 残留。
//   4) 写侧不会覆盖读侧正在读的 bank（w_bank_free 限速），从根上杜绝
//      “读侧读到上一行/下一行”的斜条纹。
//   5) 源像素进 16 深小 FIFO，写侧忙（补黑、等 bank）时不丢像素，
//      这是原实现 pend_v 单寄存器最大的坑。
//==========================================================================
module bmp_scale #(
    parameter integer DST_W = 640,
    parameter integer DST_H = 480
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [15:0] src_width,
    input  wire [15:0] src_height,
    input  wire        in_valid,
    input  wire [23:0] in_pixel,
    input  wire        out_ready,
    output reg         out_valid,
    output reg  [23:0] out_pixel,
    output reg         busy,
    output reg         done
);

    //======================================================================
    // 0. 常量（bank 偏移用 <<9 / <<7，因此行缓存行宽固定 640）
    //======================================================================
    localparam integer LINE = 640;                  // 行缓存行宽
    localparam integer NB   = 4;                    // bank 个数
    localparam [15:0]  DW16 = DST_W;                // 640
    localparam [15:0]  DH16 = DST_H;                // 480
    localparam [11:0]  COL_END  = DST_W;            // 640
    localparam [23:0]  WAIT_MAX = 24'd16_000_000;   // 看门狗 ~160ms @100MHz

    localparam [1:0] C_IDLE = 2'd0;
    localparam [1:0] C_DIV  = 2'd1;
    localparam [1:0] C_RUN  = 2'd2;

    localparam [2:0] W_ROW  = 3'd0;
    localparam [2:0] W_GET  = 3'd1;
    localparam [2:0] W_EMIT = 3'd2;
    localparam [2:0] W_PAD  = 3'd3;
    localparam [2:0] W_PUB  = 3'd4;

    localparam [2:0] R_WAIT  = 3'd0;
    localparam [2:0] R_LINE  = 3'd1;
    localparam [2:0] R_BLACK = 3'd2;
    localparam [2:0] R_VADV  = 3'd3;
    localparam [2:0] R_DONE  = 3'd4;

    //======================================================================
    // 1. 变量声明（全部先声明，避免被当成隐式 1bit 线网而把
    //    w_row / rd_line 截成 1 位 -> 只剩 2 个 bank -> 隔行混叠）
    //======================================================================
    // ---- 配置 ----
    reg [1:0]  cfg_state;
    reg        cfg_ready;
    reg [15:0] src_w_r;
    reg [15:0] src_h_r;
    reg [15:0] dst_w_r;
    reg [15:0] dst_h_r;
    reg [10:0] x0_r;
    reg [10:0] x1_r;
    reg [10:0] top0_r;
    reg        div_mode;
    reg [5:0]  div_cnt;
    reg [31:0] div_num;
    reg [31:0] div_den;
    reg [31:0] div_quo;
    reg [32:0] div_rem;

    // ---- 行缓存 ----
    reg [23:0] line_buf [0:NB*LINE-1];
    reg [23:0] rd_data_r;
    reg        wr_en;
    reg [9:0]  wr_addr;
    reg [23:0] wr_data;
    reg [1:0]  rd_bank;
    reg [15:0] bank_tag [0:NB-1];
    reg  [3:0] bank_vld;

    // ---- 写侧 ----
    reg [2:0]  w_state;
    reg [16:0] w_acc;
    reg [23:0] w_pix;
    reg [15:0] w_sx;
    reg [10:0] w_ox;
    reg [15:0] w_row;
    reg [15:0] wr_lines;
    reg [23:0] inq_mem [0:15];
    reg [3:0]  inq_wp;
    reg [3:0]  inq_rp;
    reg [4:0]  inq_cnt;

    // ---- 读侧 ----
    reg [2:0]  r_state;
    reg [15:0] rd_line;
    reg [15:0] out_row;
    reg [16:0] v_acc;
    reg        v_added;
    reg [10:0] p_cnt;
    reg        rd_row_ok;
    reg        win_q;
    reg [10:0] r_blk;
    reg [23:0] wait_cnt;
    reg        force_black;
    reg        done_r;

    //======================================================================
    // 2. 组合逻辑
    //======================================================================
    // ---- 配置：src_w*480 与 src_h*640 比较 ----
    wire [31:0] sw_x480 = ({16'd0, src_width}  << 9) - ({16'd0, src_width}  << 5);
    wire [31:0] sh_x640 = ({16'd0, src_height} << 9) + ({16'd0, src_height} << 7);
    wire        width_limited = (sw_x480 >= sh_x640);

    wire [32:0] div_shift = {div_rem[31:0], div_num[31]};
    wire [32:0] div_den33 = {1'b0, div_den};

    wire [15:0] dst_h_calc = (div_quo[15:0] == 16'd0)  ? 16'd1   :
                             (div_quo[15:0] > 16'd480) ? 16'd480 : div_quo[15:0];
    wire [15:0] dst_w_calc = (div_quo[15:0] == 16'd0)  ? 16'd1   :
                             (div_quo[15:0] > 16'd640) ? 16'd640 : div_quo[15:0];
    wire [10:0] dw11 = dst_w_calc[10:0];
    wire [10:0] dh11 = dst_h_calc[10:0];
    wire [15:0] img_end = {5'd0, top0_r} + dst_h_r;

    // ---- 行缓存地址 ----
    wire [11:0] w_base = ({10'd0, w_row[1:0]} << 9) + ({10'd0, w_row[1:0]} << 7);
    wire [11:0] r_base = ({10'd0, rd_bank}    << 9) + ({10'd0, rd_bank}    << 7);
    wire [11:0] w_addr = w_base + {2'd0, wr_addr};

    // ---- 读侧列窗口 ----
    wire        in_win  = (p_cnt >= x0_r) && (p_cnt < x1_r) && (p_cnt < COL_END);
    wire [10:0] r_off   = in_win ? (p_cnt - x0_r) : 11'd0;
    wire [11:0] r_addr  = r_base + {1'b0, r_off};
    wire        rd_en   = (r_state == R_LINE) && out_ready && (p_cnt <= COL_END);

    // ---- 写侧 DDA / bank 限速 ----
       wire [16:0] srcw17 = {1'b0, src_w_r};
    wire [16:0] dstw17 = {1'b0, dst_w_r};
    wire        w_bank_busy = bank_vld[w_row[1:0]] &&
                              (bank_tag[w_row[1:0]] >= rd_line);
    wire        rd_bank_busy = (r_state == R_LINE) && (w_row[1:0] == rd_bank);
    wire        w_bank_free = (r_state == R_DONE) ||      // 帧收尾放行
                              (!w_bank_busy && !rd_bank_busy);
                              
    // ---- 输入小 FIFO ----
    wire        q_push = in_valid && (cfg_state == C_RUN) &&
                         (w_row < src_h_r) && (inq_cnt != 5'd16);
    wire        q_pop  = (w_state == W_GET) && (inq_cnt != 5'd0);
    wire [23:0] q_data = inq_mem[inq_rp];

    //======================================================================
    // 3. 配置状态机（串行移位除法，算 dst_w / dst_h / 黑边）
    //======================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cfg_state <= C_IDLE;
            cfg_ready <= 1'b0;
            src_w_r   <= 16'd0;
            src_h_r   <= 16'd0;
            dst_w_r   <= 16'd0;
            dst_h_r   <= 16'd0;
            x0_r      <= 11'd0;
            x1_r      <= 11'd0;
            top0_r    <= 11'd0;
            div_mode  <= 1'b0;
            div_cnt   <= 6'd0;
            div_num   <= 32'd0;
            div_den   <= 32'd0;
            div_quo   <= 32'd0;
            div_rem   <= 33'd0;
        end else begin
            cfg_ready <= 1'b0;
            if (start) begin
                src_w_r   <= src_width;
                src_h_r   <= src_height;
                div_quo   <= 32'd0;
                div_rem   <= 33'd0;
                div_cnt   <= 6'd32;
                cfg_state <= C_DIV;
                if (width_limited) begin
                    div_num  <= sh_x640;
                    div_den  <= {16'd0, src_width};
                    div_mode <= 1'b1;
                    dst_w_r  <= DW16;
                    x0_r     <= 11'd0;
                    x1_r     <= 11'd640;
                end else begin
                    div_num  <= sw_x480;
                    div_den  <= {16'd0, src_height};
                    div_mode <= 1'b0;
                end
            end else if (cfg_state == C_DIV) begin
                if (div_cnt == 6'd0) begin
                    if (div_mode) begin
                        dst_h_r <= dst_h_calc;
                        top0_r  <= (11'd480 - dh11) >> 1;
                    end else begin
                        dst_w_r <= dst_w_calc;
                        x0_r    <= (11'd640 - dw11) >> 1;
                        x1_r    <= ((11'd640 - dw11) >> 1) + dw11;
                        dst_h_r <= DH16;
                        top0_r  <= 11'd0;
                    end
                    cfg_ready <= 1'b1;
                    cfg_state <= C_RUN;
                end else begin
                    if (div_shift >= div_den33) begin
                        div_rem <= div_shift - div_den33;
                        div_quo <= {div_quo[30:0], 1'b1};
                    end else begin
                        div_rem <= div_shift;
                        div_quo <= {div_quo[30:0], 1'b0};
                    end
                    div_num <= {div_num[30:0], 1'b0};
                    div_cnt <= div_cnt - 6'd1;
                end
            end
        end
    end

    //======================================================================
    // 4. 行缓存写口 / 读口（两个 always -> 推断简单双口 BRAM）
    //======================================================================
    always @(posedge clk) begin
        if (wr_en)
            line_buf[w_addr] <= wr_data;
    end

    always @(posedge clk) begin
        if (rd_en)
            rd_data_r <= line_buf[r_addr];
    end

    //======================================================================
    // 5. 输入小 FIFO（16 深 x 24bit，源像素一个都不能丢）
    //======================================================================
    always @(posedge clk or posedge rst) begin
        if (rst || start) begin
            inq_wp  <= 4'd0;
            inq_rp  <= 4'd0;
            inq_cnt <= 5'd0;
        end else begin
            if (q_push) begin
                inq_mem[inq_wp] <= in_pixel;
                inq_wp <= inq_wp + 4'd1;
            end
            if (q_pop)
                inq_rp <= inq_rp + 4'd1;

            if (q_push && !q_pop)
                inq_cnt <= inq_cnt + 5'd1;
            else if (!q_push && q_pop)
                inq_cnt <= inq_cnt - 5'd1;
        end
    end

    //======================================================================
    // 6. 写侧状态机
    //    W_ROW  : 等 bank 可用 -> W_GET
    //    W_GET  : 取一个源像素（没有就等，绝不丢）
    //    W_EMIT : 按水平 DDA 把该像素重复写到 w_ox
    //    W_PAD  : 剩余列补 24'd0，直到 w_ox == 640
    //    W_PUB  : 640 列全部写完，才发布（tag + vld）
    //======================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            w_state  <= W_ROW;
            w_acc    <= 17'd0;
            w_pix    <= 24'd0;
            w_sx     <= 16'd0;
            w_ox     <= 11'd0;
            w_row    <= 16'd0;
            wr_lines <= 16'd0;
            wr_en    <= 1'b0;
            wr_addr  <= 10'd0;
            wr_data  <= 24'd0;
            bank_vld <= 4'b0000;
        end else if (start) begin
            w_state  <= W_ROW;
            w_acc    <= 17'd0;
            w_pix    <= 24'd0;
            w_sx     <= 16'd0;
            w_ox     <= 11'd0;
            w_row    <= 16'd0;
            wr_lines <= 16'd0;
            wr_en    <= 1'b0;
            bank_vld <= 4'b0000;
        end else begin
            wr_en <= 1'b0;
            if (cfg_state == C_RUN) begin
                case (w_state)
                    //------------------------------------------------------
                    W_ROW: begin
                        if ((src_w_r != 16'd0) && (w_row < src_h_r) && w_bank_free) begin
                            bank_vld[w_row[1:0]] <= 1'b0;   // 该 bank 进入覆写
                            w_pix   <= 24'd0;
                            w_sx    <= 16'd0;
                            w_ox    <= 11'd0;
                            w_acc   <= 17'd0;
                            w_state <= W_GET;
                        end
                    end
                    //------------------------------------------------------
                    W_GET: begin
                        if (inq_cnt != 5'd0) begin
                            w_pix   <= q_data;
                            w_sx    <= w_sx + 16'd1;
                            w_acc   <= w_acc + dstw17;
                            w_state <= W_EMIT;
                        end
                    end
                    //------------------------------------------------------
                    W_EMIT: begin
                        if ((w_acc >= srcw17) && (w_ox < COL_END)) begin
                            wr_en   <= 1'b1;
                            wr_data <= w_pix;
                            wr_addr <= w_ox[9:0];
                            w_ox    <= w_ox + 11'd1;
                            w_acc   <= w_acc - srcw17;
                        end else if (w_sx >= src_w_r) begin
                            w_state <= W_PAD;               // 本行源像素已取完
                        end else begin
                            w_state <= W_GET;               // 下采样：这个像素不输出
                        end
                    end
                    //------------------------------------------------------
                    W_PAD: begin
                        if (w_ox < COL_END) begin
                            wr_en   <= 1'b1;
                            wr_data <= 24'd0;               // 纯黑补齐
                            wr_addr <= w_ox[9:0];
                            w_ox    <= w_ox + 11'd1;
                        end else begin
                            w_state <= W_PUB;
                        end
                    end
                    //------------------------------------------------------
                    W_PUB: begin
                        bank_tag[w_row[1:0]] <= w_row;
                        bank_vld[w_row[1:0]] <= 1'b1;       // 640 列落地后才置位
                        wr_lines <= wr_lines + 16'd1;
                        w_row    <= w_row + 16'd1;
                        w_state  <= W_ROW;
                    end
                    default: w_state <= W_ROW;
                endcase
            end
        end
    end

    //======================================================================
    // 7. 读侧状态机
    //    R_LINE : p_cnt = 0..641，共 642 拍，输出恰好 640 个像素
    //             p_cnt = k : 发第 k 列的 BRAM 地址
    //             p_cnt = k : out_pixel <= 第 k-1 列锁存的 rd_data_r
    //             BRAM 1 拍延迟被完全吸收，无空拍、不重复、不丢
    //    R_BLACK: 640 个纯黑像素
    //    R_VADV : 垂直 DDA（Bresenham）推进 rd_line
    //======================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            r_state     <= R_WAIT;
            rd_line     <= 16'd0;
            out_row     <= 16'd0;
            v_acc       <= 17'd0;
            v_added     <= 1'b0;
            p_cnt       <= 11'd0;
            rd_bank     <= 2'd0;
            rd_row_ok   <= 1'b0;
            win_q       <= 1'b0;
            r_blk       <= 11'd0;
            wait_cnt    <= 24'd0;
            force_black <= 1'b0;
            out_valid   <= 1'b0;
            out_pixel   <= 24'd0;
            done_r      <= 1'b0;
        end else if (start || (cfg_state != C_RUN)) begin
            r_state     <= R_WAIT;
            rd_line     <= 16'd0;
            out_row     <= 16'd0;
            v_acc       <= 17'd0;
            v_added     <= 1'b0;
            p_cnt       <= 11'd0;
            rd_row_ok   <= 1'b0;
            win_q       <= 1'b0;
            r_blk       <= 11'd0;
            wait_cnt    <= 24'd0;
            force_black <= 1'b0;
            out_valid   <= 1'b0;
            out_pixel   <= 24'd0;
            done_r      <= 1'b0;
        end else begin
            case (r_state)
                //----------------------------------------------------------
                R_WAIT: begin
                    out_valid <= 1'b0;
                    out_pixel <= 24'd0;

                    if (out_row >= DH16) begin
                        r_state <= R_DONE;                  // 480 行出完
                    end else if (force_black || (out_row < top0_r) ||
                                 (out_row >= img_end)) begin
                        r_blk   <= 11'd0;                   // 上下黑边
                        r_state <= R_BLACK;
                    end else if (rd_line >= src_h_r) begin
                        force_black <= 1'b1;                // 行号越界，本帧余下全黑
                    end else if (bank_vld[rd_line[1:0]] &&
                                 (bank_tag[rd_line[1:0]] == rd_line)) begin
                        // 只有“整行 640 列已写完 + 行号匹配”才允许读
                        rd_bank   <= rd_line[1:0];
                        rd_row_ok <= 1'b1;
                        p_cnt     <= 11'd0;
                        wait_cnt  <= 24'd0;
                        r_state   <= R_LINE;
                    end else if (wr_lines >= src_h_r) begin
                        force_black <= 1'b1;                // 源行全发完仍拿不到，不死等
                    end else if (wait_cnt >= WAIT_MAX) begin
                        force_black <= 1'b1;                // 看门狗
                    end else begin
                        wait_cnt <= wait_cnt + 24'd1;
                    end
                end
                //----------------------------------------------------------
                R_LINE: begin
                    if (out_ready) begin
                        // 输出级：用上一拍锁存的 rd_data_r 与 win_q，严格对齐
                        out_valid <= ((p_cnt >= 11'd1) && (p_cnt <= COL_END)) ? 1'b1 : 1'b0;
                        out_pixel <= ((p_cnt >= 11'd1) && (p_cnt <= COL_END) &&
                                      rd_row_ok && win_q) ? rd_data_r : 24'd0;
                        win_q <= in_win;

                        if (p_cnt > COL_END) begin
                            p_cnt   <= 11'd0;
                            r_state <= R_VADV;
                        end else begin
                            p_cnt <= p_cnt + 11'd1;
                        end
                    end
                    // out_ready = 0：地址/数据/标志整体冻结，像素不丢不重
                end
                //----------------------------------------------------------
                R_BLACK: begin
                    if (out_ready) begin
                        if (r_blk < COL_END) begin
                            out_valid <= 1'b1;
                            out_pixel <= 24'd0;
                            r_blk     <= r_blk + 11'd1;
                        end else begin
                            out_valid <= 1'b0;
                            out_pixel <= 24'd0;
                            r_blk     <= 11'd0;
                            out_row   <= out_row + 16'd1;
                            r_state   <= R_WAIT;
                        end
                    end
                end
                //----------------------------------------------------------
                R_VADV: begin
                    out_valid <= 1'b0;
                    if (!v_added) begin
                        v_acc   <= v_acc + {1'b0, src_h_r};
                        v_added <= 1'b1;
                    end else if (v_acc >= {1'b0, dst_h_r}) begin
                        v_acc   <= v_acc - {1'b0, dst_h_r};
                        rd_line <= rd_line + 16'd1;         // 下采样时连续跳行
                    end else begin
                        v_added <= 1'b0;
                        out_row <= out_row + 16'd1;
                        r_state <= R_WAIT;
                    end
                end
                //----------------------------------------------------------
                R_DONE: begin
                    out_valid <= 1'b0;
                    done_r    <= 1'b1;
                end
                default: r_state <= R_WAIT;
            endcase
        end
    end

    //======================================================================
    // 8. busy / done（done 为电平，保持到下一次 start）
    //======================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
        end else if (start) begin
            busy <= 1'b1;
            done <= 1'b0;
        end else if (done_r) begin
            busy <= 1'b0;
            done <= 1'b1;
        end
    end

endmodule