//============================================================================
// 模块名称: xfd_line_fetch
// 功能描述: 图片切换淡入淡出转场 —— 逐行双取数引擎
//
// 时序优化:
//   1) App_rd_en / App_rd_addr 由最终输出寄存器同拍输出；
//      请求计数、地址递推在“预请求”级完成，输出级只打拍。
//   2) 行偏移 row_off_r 每行递增 640，消除 row_lat*640。
//   3) 读地址 rd_addr_cur 每请求 +1，640 边界切新图基址，
//      消除 phase 比较 + 减法 + 双加法。
//   4) burst 判断改为 burst_cnt < BURST_SIZE，去掉加法器。
//   5) 行缓存写侧 wr_en/wr_addr/wr_data/wr_page 统一打一拍。
//
// 时钟域: mem_clk = 125MHz
//============================================================================

`timescale 1ns / 1ps

module xfd_line_fetch #(
    parameter ADDR_BITS  = 21,
    parameter LINE_LEN   = 640,
    parameter ROW_MAX    = 479,
    parameter BURST_SIZE = 256
)(
    input  wire                  rst,
    input  wire                  mem_clk,
    input  wire                  xfd_en,
    input  wire                  vs_tgl,
    input  wire                  line_tgl,
    input  wire [ADDR_BITS-1:0]  old_base,
    input  wire [ADDR_BITS-1:0]  new_base,
    output wire                  App_rd_en,
    output wire [ADDR_BITS-1:0]  App_rd_addr,
    input  wire                  Sdr_rd_en,
    input  wire [31:0]           Sdr_rd_dout,
    output wire                  wr_en_old,
    output wire                  wr_en_new,
    output wire                  wr_page,
    output wire [9:0]            wr_addr,
    output wire [31:0]           wr_data,
    output wire [9:0]            fetch_row,
    output wire                  busy
);

    //==========================================================================
    // 常量
    //==========================================================================
    localparam TOTAL       = LINE_LEN * 2;                     // 1280
    localparam BURST_BITS  = $clog2(BURST_SIZE) + 2;           // 10
    localparam [BURST_BITS-1:0] BURST_SIZE_W = BURST_SIZE[BURST_BITS-1:0];

    localparam [10:0]           TOTAL_W   = TOTAL;             // 1280
    localparam [10:0]           LINE_LAST = LINE_LEN - 1;      // 639
    localparam [9:0]            COL_LAST  = LINE_LEN - 1;      // 639
    localparam [ADDR_BITS-1:0]  LINE_STEP = LINE_LEN;          // 640

    localparam [12:0] TMO_MAX = 13'h1FFF;                       // 8191 拍

    localparam [1:0] F_IDLE  = 2'd0;
    localparam [1:0] F_REQ   = 2'd1;
    localparam [1:0] F_DRAIN = 2'd2;

    //==========================================================================
    // 寄存器声明
    //==========================================================================
    reg        vs_tgl_d;
    reg        line_tgl_d;
    reg        xfd_en_d;

    reg [9:0]  row_ptr;
    reg [ADDR_BITS-1:0] row_off_r;

    reg [1:0]  fsm_state;
    reg        busy_r;
    reg [9:0]  row_lat;
    reg        need_r;
    reg        app_rd_en_r;

    reg [ADDR_BITS-1:0] old_row_base_r;
    reg [ADDR_BITS-1:0] new_row_base_r;

    reg [10:0] addr_cnt;              // 已形成的预请求数 0..1280
    reg [ADDR_BITS-1:0] rd_addr_cur;  // 当前预请求地址

    reg [BURST_BITS-1:0] burst_cnt;
    reg [3:0]  rd_dly;
    reg [10:0] rcnt;
    reg [12:0] drain_tmo;

    reg [9:0]  wr_col;                // 0..639，自动回绕

    // 最终输出寄存器（SDRAM 端口）
    reg        app_rd_en_o;
    reg [ADDR_BITS-1:0] app_rd_addr_o;

    // 行缓存写侧输出寄存器
    reg        wr_en_old_o;
    reg        wr_en_new_o;
    reg        wr_page_o;
    reg [9:0]  wr_addr_o;
    reg [31:0] wr_data_o;

    //==========================================================================
    // 组合信号
    //==========================================================================
    wire vs_pulse    = vs_tgl   ^ vs_tgl_d;
    wire line_pulse  = line_tgl ^ line_tgl_d;
    wire xfd_en_rise = xfd_en & ~xfd_en_d;
    wire start_new   = xfd_en_rise | vs_pulse;

    wire start_fetch = (fsm_state == F_IDLE) && need_r && ~busy_r;
    wire drain_done  = (rd_dly == 4'd10);

    // 预请求条件：每项最多一个比较器，比较器之间并行
    wire req_ok = app_rd_en_r &&
                  (fsm_state == F_REQ) &&
                  (addr_cnt < TOTAL_W) &&
                  (burst_cnt < BURST_SIZE_W);

    // 下一个请求地址：640 边界切到新图基址，否则 +1
    wire [ADDR_BITS-1:0] rd_addr_nxt =
        (addr_cnt == LINE_LAST) ? new_row_base_r : (rd_addr_cur + 1'b1);

    wire recv_is_old = (rcnt < LINE_LEN);
    wire wr_accept   = busy_r && Sdr_rd_en && xfd_en && (rcnt < TOTAL_W);
    wire wr_en_old_c = wr_accept && recv_is_old;
    wire wr_en_new_c = wr_accept && ~recv_is_old;

    //==========================================================================
    // 边沿检测 / 行号 / 行偏移
    //==========================================================================
    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            vs_tgl_d   <= 1'b0;
            line_tgl_d <= 1'b0;
            xfd_en_d   <= 1'b0;
            row_ptr    <= 10'd0;
            row_off_r  <= {ADDR_BITS{1'b0}};
        end else begin
            vs_tgl_d   <= vs_tgl;
            line_tgl_d <= line_tgl;
            xfd_en_d   <= xfd_en;

            if (~xfd_en) begin
                row_ptr   <= 10'd0;
                row_off_r <= {ADDR_BITS{1'b0}};
            end else if (start_new) begin
                row_ptr   <= 10'd0;
                row_off_r <= {ADDR_BITS{1'b0}};
            end else if (line_pulse) begin
                if (row_ptr <= ROW_MAX - 1) begin
                    row_ptr   <= row_ptr + 10'd1;
                    row_off_r <= row_off_r + LINE_STEP;
                end
            end
        end
    end

    //==========================================================================
    // 取数状态机
    //==========================================================================
    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            fsm_state      <= F_IDLE;
            busy_r         <= 1'b0;
            row_lat        <= 10'd0;
            need_r         <= 1'b0;
            app_rd_en_r    <= 1'b0;
            old_row_base_r <= {ADDR_BITS{1'b0}};
            new_row_base_r <= {ADDR_BITS{1'b0}};
        end else if (~xfd_en) begin
            fsm_state      <= F_IDLE;
            busy_r         <= 1'b0;
            need_r         <= 1'b0;
            app_rd_en_r    <= 1'b0;
            old_row_base_r <= {ADDR_BITS{1'b0}};
            new_row_base_r <= {ADDR_BITS{1'b0}};
        end else begin
            if (start_new || line_pulse)
                need_r <= 1'b1;

            case (fsm_state)
                F_IDLE: begin
                    if (need_r && ~busy_r) begin
                        busy_r         <= 1'b1;
                        need_r         <= 1'b0;
                        row_lat        <= row_ptr;
                        fsm_state      <= F_REQ;
                        app_rd_en_r    <= 1'b1;
                        old_row_base_r <= old_base + row_off_r;
                        new_row_base_r <= new_base + row_off_r;
                    end
                end

                F_REQ: begin
                    if (addr_cnt >= TOTAL_W) begin
                        fsm_state   <= F_DRAIN;
                        app_rd_en_r <= 1'b0;
                    end
                end

                F_DRAIN: begin
                    if (rcnt >= TOTAL_W || drain_tmo == TMO_MAX) begin
                        fsm_state   <= F_IDLE;
                        busy_r      <= 1'b0;
                        app_rd_en_r <= 1'b0;
                    end
                end

                default: fsm_state <= F_IDLE;
            endcase
        end
    end

    //==========================================================================
    // 预请求地址 / 请求计数
    //   每行开始装载 old_base + row_off_r
    //   每个预请求地址 +1，640 边界切到 new_row_base_r
    //==========================================================================
    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            addr_cnt    <= 11'd0;
            rd_addr_cur <= {ADDR_BITS{1'b0}};
        end else if (~xfd_en) begin
            addr_cnt    <= 11'd0;
            rd_addr_cur <= {ADDR_BITS{1'b0}};
        end else if (start_fetch) begin
            addr_cnt    <= 11'd0;
            rd_addr_cur <= old_base + row_off_r;
        end else if (fsm_state != F_REQ) begin
            addr_cnt    <= 11'd0;
            // rd_addr_cur 保持，等待下一次 start_fetch 装载
        end else if (req_ok) begin
            addr_cnt    <= addr_cnt + 11'd1;
            rd_addr_cur <= rd_addr_nxt;
        end
    end

    //==========================================================================
    // SDRAM 最终输出寄存器
    //   req_ok / rd_addr_cur 是预请求级，这里同拍打拍输出
    //==========================================================================
    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            app_rd_en_o   <= 1'b0;
            app_rd_addr_o <= {ADDR_BITS{1'b0}};
        end else if (~xfd_en) begin
            app_rd_en_o   <= 1'b0;
            app_rd_addr_o <= {ADDR_BITS{1'b0}};
        end else begin
            app_rd_en_o   <= req_ok;
            app_rd_addr_o <= rd_addr_cur;
        end
    end

    assign App_rd_en   = app_rd_en_o;
    assign App_rd_addr = app_rd_addr_o;

    //==========================================================================
    // burst 计数 / drain 间隔
    //   每发一个预请求 burst_cnt+1，达到 BURST_SIZE 后停止
    //   停发后 rd_dly 计到 10，清 burst_cnt，允许下一 burst
    //==========================================================================
    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            burst_cnt <= {BURST_BITS{1'b0}};
            rd_dly    <= 4'd0;
        end else if (~xfd_en || fsm_state != F_REQ) begin
            burst_cnt <= {BURST_BITS{1'b0}};
            rd_dly    <= 4'd0;
        end else if (req_ok) begin
            burst_cnt <= burst_cnt + 1'b1;
            rd_dly    <= 4'd0;
        end else if (drain_done) begin
            burst_cnt <= {BURST_BITS{1'b0}};
            // rd_dly 保持 10，下一拍 req_ok 时清零
        end else if (rd_dly < 4'd10) begin
            rd_dly <= rd_dly + 1'b1;
        end
    end

    //==========================================================================
    // 接收数据计数
    //==========================================================================
    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            rcnt <= 11'd0;
        end else if (~xfd_en || fsm_state == F_IDLE) begin
            rcnt <= 11'd0;
        end else if (Sdr_rd_en && rcnt < TOTAL_W) begin
            rcnt <= rcnt + 11'd1;
        end
    end

    //==========================================================================
    // DRAIN 超时
    //==========================================================================
    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            drain_tmo <= 13'd0;
        end else if (fsm_state != F_DRAIN) begin
            drain_tmo <= 13'd0;
        end else if (drain_tmo < TMO_MAX) begin
            drain_tmo <= drain_tmo + 13'd1;
        end
    end

    //==========================================================================
    // 行缓存写列地址 0..639，自动回绕
    //   消除 rcnt - 640 的减法和二选一
    //==========================================================================
    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            wr_col <= 10'd0;
        end else if (~xfd_en || fsm_state == F_IDLE) begin
            wr_col <= 10'd0;
        end else if (Sdr_rd_en && rcnt < TOTAL_W) begin
            if (wr_col == COL_LAST)
                wr_col <= 10'd0;
            else
                wr_col <= wr_col + 1'b1;
        end
    end

    //==========================================================================
    // 行缓存写侧输出寄存器
    //   wr_en/wr_addr/wr_data/wr_page 同拍打拍，保持彼此对齐
    //==========================================================================
    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            wr_en_old_o <= 1'b0;
            wr_en_new_o <= 1'b0;
            wr_page_o   <= 1'b0;
            wr_addr_o   <= 10'd0;
            wr_data_o   <= 32'd0;
        end else begin
            wr_en_old_o <= wr_en_old_c;
            wr_en_new_o <= wr_en_new_c;
            wr_page_o   <= row_lat[0];
            wr_addr_o   <= wr_col;
            wr_data_o   <= Sdr_rd_dout;
        end
    end

    assign wr_en_old = wr_en_old_o;
    assign wr_en_new = wr_en_new_o;
    assign wr_page   = wr_page_o;
    assign wr_addr   = wr_addr_o;
    assign wr_data   = wr_data_o;

    assign fetch_row = row_lat;
    assign busy      = busy_r;

endmodule