//=============================================================================
// top_skeleton.sv —— 图片切换淡入淡出转场 · 顶层骨架（编译导向，无业务逻辑）
// 工程：med_screen（安路 EG4S20BG256B）
//
// 说明：
//   1) 本文件是“转场子系统的顶层连接骨架”，用于冻结接口、供后续 RTL 生成与
//      编译检查对照；它不是要替换工程的既有顶层 ``top_tf_hdmi_audio.v``。
//   2) 既有顶层文件里的 TF/HDMI/音频/PLL 等实例保持不动，本骨架只画出本次
//      新增/改动部分：3 个新模块、4 个行缓存 BRAM、读端口仲裁、显示二选一、
//      以及 5 处 CDC 同步器。
//   3) 骨架内 ``blackbox_*`` 与 ``external_*`` 均为占位端口/实例，仅表达连接关系。
//=============================================================================
`timescale 1ns/1ps

module top_skeleton
(
    input  wire        refclk,
    input  wire        rst_n,
    input  wire        key1,
    input  wire        key2,
    input  wire        key3,

    output wire [5:0]  seg_sel,
    output wire [7:0]  seg_data,

    output wire        HDMI_CLK_P,
    output wire        HDMI_D2_P,
    output wire        HDMI_D1_P,
    output wire        HDMI_D0_P,

    output wire        HDMI_DDC_SCL,
    inout  wire        HDMI_DDC_SDA,

    output wire        sd_ncs,
    output wire        sd_dclk,
    output wire        sd_mosi,
    input  wire        sd_miso
);

    //--------------------------------------------------------------------------
    // 参数
    //--------------------------------------------------------------------------
    localparam ADDR_BITS  = 21;
    localparam LINE_LEN   = 640;
    localparam BUF0_ADDR  = 21'd0;
    localparam BUF1_ADDR  = 21'd307200;
    localparam BUF2_ADDR  = 21'd614400;   // 本次保留未用
    localparam ALPHA_STEP = 4;            // 每帧 alpha 增量（4≈1.07s，8≈0.53s）

    //--------------------------------------------------------------------------
    // 时钟 / 复位（既有 PLL 产生，这里只声明）
    //--------------------------------------------------------------------------
    wire video_clk;
    wire ext_mem_clk;
    wire sd_card_clk;
    wire rst_all = ~rst_n;   // 实际工程为 ~rst_n | ~audio_pll_lock

    //--------------------------------------------------------------------------
    // 视频时序（既有）
    //--------------------------------------------------------------------------
    wire hs_0, vs_0, de_0;

    blackbox_video_timing_data u_timing (
        .video_clk  (video_clk),
        .rst        (rst_all),
        .xfd_en     (xfd_en_v),        // 新增端口
        .read_req   (video_read_req),  // 每帧一次；xfd_en 时强制 0
        .read_req_ack (video_read_req_ack),
        .hs         (hs_0),
        .vs         (vs_0),
        .de         (de_0)
    );

    //--------------------------------------------------------------------------
    // 非转场显示通路（既有）
    //--------------------------------------------------------------------------
    wire        hs_r, vs_r, de_r;
    wire [23:0] vout_data_fifo;

    blackbox_video_delay u_video_delay (
        .video_clk (video_clk),
        .rst       (rst_all),
        .read_en   (video_read_en),
        .read_data (video_read_data[31:8]),
        .hs        (hs_0),
        .vs        (vs_0),
        .de        (de_0),
        .hs_r      (hs_r),
        .vs_r      (vs_r),
        .de_r      (de_r),
        .vout_data (vout_data_fifo)
    );

    //--------------------------------------------------------------------------
    // 帧缓存读写引擎（既有，含 frame_fifo_write / frame_fifo_read）
    //   - read_addr_index = disp_buf_idx（sd 域，需按既有方式送达）
    //   - read_len        = 307200（整帧）；frame_fifo_read 内去掉 rd_toggle
    //--------------------------------------------------------------------------
    wire [1:0]  disp_buf_idx;      // 来自 sd_card_bmp（sd 域）
    wire [1:0]  write_buf_idx;     // 来自 sd_card_bmp（sd 域）
    wire        fifo_App_rd_en;
    wire [ADDR_BITS-1:0] fifo_App_rd_addr;
    wire        App_rd_en;
    wire [ADDR_BITS-1:0] App_rd_addr;
    wire        App_wr_en;
    wire [ADDR_BITS-1:0] App_wr_addr;
    wire [31:0] App_wr_din;
    wire [3:0]  App_wr_dm;
    wire        Sdr_rd_en;
    wire [31:0] Sdr_rd_dout;

    blackbox_frame_read_write u_frame_rw (
        .mem_clk          (ext_mem_clk),
        .rst              (rst_all),
        .read_clk         (video_clk),
        .read_req         (video_read_req),
        .read_req_ack     (video_read_req_ack),
        .read_addr_0      (BUF0_ADDR),
        .read_addr_1      (BUF1_ADDR),
        .read_addr_2      (BUF2_ADDR),
        .read_addr_3      (21'd0),
        .read_addr_index  (disp_buf_idx),
        .read_len         (307200),
        .read_en          (video_read_en),
        .read_data        (video_read_data),
        .App_rd_en        (fifo_App_rd_en),
        .App_rd_addr      (fifo_App_rd_addr),
        .Sdr_rd_en        (Sdr_rd_en & ~xfd_en_mem),   // 新增：转场期间门控读 FIFO 写入
        .Sdr_rd_dout      (Sdr_rd_dout),
        .App_wr_en        (App_wr_en),
        .App_wr_addr      (App_wr_addr),
        .App_wr_din       (App_wr_din),
        .App_wr_dm        (App_wr_dm),
        .write_clk        (sd_card_clk),
        .write_addr_0     (BUF0_ADDR),
        .write_addr_1     (BUF1_ADDR),
        .write_addr_2     (BUF2_ADDR),
        .write_addr_3     (21'd0),
        .write_addr_index (write_buf_idx)
        // ... write_req/write_finish/write_len/write_en/write_data 等既有连接省略
    );

    //--------------------------------------------------------------------------
    // 转场控制器（新增，video_clk 域）
    //--------------------------------------------------------------------------
    wire        xfd_en_v;
    wire        xfd_busy_v;
    wire [8:0]  alpha;
    wire [1:0]  old_idx;
    wire [1:0]  new_idx;
    wire        vs_tgl;
    wire        line_tgl;

    xfd_ctrl #(
        .ALPHA_STEP (ALPHA_STEP),
        .BUF_STRIDE (307200),
        .BUF0_ADDR  (BUF0_ADDR)
    ) u_xfd_ctrl (
        .video_clk    (video_clk),
        .rst          (rst_all),
        .disp_buf_idx (disp_buf_idx),      // 内部 2-FF 同步（sd→video）
        .hs_in        (hs_0),
        .vs_in        (vs_0),
        .de_in        (de_0),
        .xfd_en       (xfd_en_v),
        .xfd_busy     (xfd_busy_v),
        .alpha        (alpha),
        .old_idx      (old_idx),
        .new_idx      (new_idx),
        .vs_tgl       (vs_tgl),
        .line_tgl     (line_tgl)
    );

    //--------------------------------------------------------------------------
    // CDC：video → mem（xfd_en / old_idx / new_idx / 脉冲），video → sd（xfd_busy）
    //--------------------------------------------------------------------------
    wire xfd_en_mem;
    sync_2ff u_sync_xfd_en_mem (.clk(ext_mem_clk), .rst(rst_all), .d(xfd_en_v),   .q(xfd_en_mem));
    wire xfd_busy_sd;
    sync_2ff u_sync_xfd_busy_sd(.clk(sd_card_clk),.rst(rst_all), .d(xfd_busy_v), .q(xfd_busy_sd));

    wire [1:0] old_idx_mem;
    sync_2ff u_sync_old_idx0 (.clk(ext_mem_clk), .rst(rst_all), .d(old_idx[0]), .q(old_idx_mem[0]));
    sync_2ff u_sync_old_idx1 (.clk(ext_mem_clk), .rst(rst_all), .d(old_idx[1]), .q(old_idx_mem[1]));
    wire [1:0] new_idx_mem;
    sync_2ff u_sync_new_idx0 (.clk(ext_mem_clk), .rst(rst_all), .d(new_idx[0]), .q(new_idx_mem[0]));
    sync_2ff u_sync_new_idx1 (.clk(ext_mem_clk), .rst(rst_all), .d(new_idx[1]), .q(new_idx_mem[1]));

    // 脉冲同步（toggle + 边沿检测）
    wire vs_tgl_s0, vs_tgl_s1, vs_tgl_s2;
    wire line_tgl_s0, line_tgl_s1, line_tgl_s2;
    sync_2ff u_sync_vs0   (.clk(ext_mem_clk), .rst(rst_all), .d(vs_tgl),   .q(vs_tgl_s0));
    sync_2ff u_sync_vs1   (.clk(ext_mem_clk), .rst(rst_all), .d(vs_tgl_s0),.q(vs_tgl_s1));
    sync_2ff u_sync_line0 (.clk(ext_mem_clk), .rst(rst_all), .d(line_tgl), .q(line_tgl_s0));
    sync_2ff u_sync_line1 (.clk(ext_mem_clk), .rst(rst_all), .d(line_tgl_s0),.q(line_tgl_s1));
    wire vs_tgl_pulse   = vs_tgl_s1   ^ vs_tgl_s0;
    wire line_tgl_pulse = line_tgl_s1 ^ line_tgl_s0;

    //--------------------------------------------------------------------------
    // 帧缓冲基址映射（mem 域）
    //--------------------------------------------------------------------------
    wire [ADDR_BITS-1:0] old_base =
        (old_idx_mem == 2'd0) ? BUF0_ADDR :
        (old_idx_mem == 2'd1) ? BUF1_ADDR : BUF2_ADDR;
    wire [ADDR_BITS-1:0] new_base =
        (new_idx_mem == 2'd0) ? BUF0_ADDR :
        (new_idx_mem == 2'd1) ? BUF1_ADDR : BUF2_ADDR;

    //--------------------------------------------------------------------------
    // 逐行双取数引擎（新增，mem_clk 域）
    //--------------------------------------------------------------------------
    wire        xfd_App_rd_en, xfd_wr_en_old, xfd_wr_en_new, xfd_wr_page, xfd_busy_mem;
    wire [ADDR_BITS-1:0] xfd_App_rd_addr;
    wire [9:0]  xfd_wr_addr;
    wire [31:0] xfd_wr_data;
    wire [9:0]  fetch_row;

    xfd_line_fetch #(
        .ADDR_BITS  (ADDR_BITS),
        .LINE_LEN   (LINE_LEN),
        .ROW_MAX    (480),
        .BURST_SIZE (256)
    ) u_xfd_fetch (
        .rst         (rst_all),
        .mem_clk     (ext_mem_clk),
        .xfd_en      (xfd_en_mem),
        .vs_tgl      (vs_tgl_s0),
        .line_tgl    (line_tgl_s0),
        .old_base    (old_base),
        .new_base    (new_base),
        .App_rd_en   (xfd_App_rd_en),
        .App_rd_addr (xfd_App_rd_addr),
        .Sdr_rd_en   (Sdr_rd_en),
        .Sdr_rd_dout (Sdr_rd_dout),
        .wr_en_old   (xfd_wr_en_old),
        .wr_en_new   (xfd_wr_en_new),
        .wr_page     (xfd_wr_page),
        .wr_addr     (xfd_wr_addr),
        .wr_data     (xfd_wr_data),
        .fetch_row   (fetch_row),
        .busy        (xfd_busy_mem)
    );

    //--------------------------------------------------------------------------
    // 行缓存：4 × RAM_0（1024x32 Simple Dual Port，写=mem，读=video）
    //--------------------------------------------------------------------------
    wire [9:0]  rd_addr;
    wire        rd_page;
    wire [31:0] old_p0_dob, old_p1_dob, new_p0_dob, new_p1_dob;
    wire [31:0] old_dob, new_dob;

    RAM_0 u_ram_old_p0 (
        .clka (ext_mem_clk), .cea (xfd_wr_en_old & ~xfd_wr_page), .addra(xfd_wr_addr), .dia(xfd_wr_data),
        .clkb (video_clk),   .addrb(rd_addr), .dob(old_p0_dob)
    );
    RAM_0 u_ram_old_p1 (
        .clka (ext_mem_clk), .cea (xfd_wr_en_old &  xfd_wr_page), .addra(xfd_wr_addr), .dia(xfd_wr_data),
        .clkb (video_clk),   .addrb(rd_addr), .dob(old_p1_dob)
    );
    RAM_0 u_ram_new_p0 (
        .clka (ext_mem_clk), .cea (xfd_wr_en_new & ~xfd_wr_page), .addra(xfd_wr_addr), .dia(xfd_wr_data),
        .clkb (video_clk),   .addrb(rd_addr), .dob(new_p0_dob)
    );
    RAM_0 u_ram_new_p1 (
        .clka (ext_mem_clk), .cea (xfd_wr_en_new &  xfd_wr_page), .addra(xfd_wr_addr), .dia(xfd_wr_data),
        .clkb (video_clk),   .addrb(rd_addr), .dob(new_p1_dob)
    );

    assign old_dob = rd_page ? old_p1_dob : old_p0_dob;
    assign new_dob = rd_page ? new_p1_dob : new_p0_dob;

    //--------------------------------------------------------------------------
    // 视频域混合流水（新增，video_clk 域），延迟 20 拍，与 video_delay 同构
    //--------------------------------------------------------------------------
    wire        xfd_hs, xfd_vs, xfd_de;
    wire [23:0] xfd_rgb;
    wire [9:0]  disp_row;

    xfd_disp_pipe #(
        .LINE_LEN (LINE_LEN),
        .LAT      (20)
    ) u_xfd_pipe (
        .video_clk (video_clk),
        .rst       (rst_all),
        .xfd_en    (xfd_en_v),
        .alpha     (alpha),
        .hs_in     (hs_0),
        .vs_in     (vs_0),
        .de_in     (de_0),
        .rd_page   (rd_page),
        .rd_addr   (rd_addr),
        .old_dob   (old_dob),
        .new_dob   (new_dob),
        .hs_out    (xfd_hs),
        .vs_out    (xfd_vs),
        .de_out    (xfd_de),
        .rgb_out   (xfd_rgb),
        .disp_row  (disp_row)
    );

    //--------------------------------------------------------------------------
    // 显示二选一：仅 xfd_en 变化时切换，且该变化严格落在帧边界
    //--------------------------------------------------------------------------
    wire        hs        = xfd_en_v ? xfd_hs  : hs_r;
    wire        vs        = xfd_en_v ? xfd_vs  : vs_r;
    wire        de        = xfd_en_v ? xfd_de  : de_r;
    wire [23:0] vout_data_raw = xfd_en_v ? xfd_rgb : vout_data_fifo[23:0];

    // 下游链路（亮度 → 字幕 → RGB2AXIS → HDMI）完全沿用既有实例，
    // 此处只声明接口以表达连接：
    wire [23:0] vout_data_bright, vout_data_osd, vout_data;
    blackbox_brightness_ctrl u_bright (
        .clk(video_clk), .rst(rst_all), .de(de), .key(key3),
        .rgb_in(vout_data_raw), .rgb_out(vout_data_bright), .brightness_val()
    );
    blackbox_osd_overlay u_osd (
        .clk(video_clk), .rst(rst_all), .hs(hs), .vs(vs), .de(de),
        .rgb_in(vout_data_bright), .rgb_out(vout_data_osd)
    );
    assign vout_data = vout_data_osd;

    //--------------------------------------------------------------------------
    // 读端口仲裁（mem 域）
    //--------------------------------------------------------------------------
    assign App_rd_en   = xfd_en_mem ? xfd_App_rd_en   : fifo_App_rd_en;
    assign App_rd_addr = xfd_en_mem ? xfd_App_rd_addr : fifo_App_rd_addr;

    //--------------------------------------------------------------------------
    // 黑盒：嵌入式 SDRAM 控制器（既有）
    //--------------------------------------------------------------------------
    blackbox_sdram u_sdram (
        .Clk          (ext_mem_clk),
        .Rst          (rst_all),
        .App_rd_en    (App_rd_en),
        .App_rd_addr  (App_rd_addr),
        .Sdr_rd_en    (Sdr_rd_en),
        .Sdr_rd_dout  (Sdr_rd_dout),
        .App_wr_en    (App_wr_en),
        .App_wr_addr  (App_wr_addr),
        .App_wr_din   (App_wr_din),
        .App_wr_dm    (App_wr_dm)
    );

    //--------------------------------------------------------------------------
    // 黑盒：TF 卡图片源 + 缓冲索引产生（既有，新增 xfd_busy 输入）
    //--------------------------------------------------------------------------
    blackbox_sd_card_bmp u_sd_card_bmp (
        .clk          (sd_card_clk),
        .rst          (rst_all),
        .key_next     (key1),
        .key_auto     (key2),
        .xfd_busy     (xfd_busy_sd),   // 新增端口
        .write_buf_idx(write_buf_idx),
        .disp_buf_idx (disp_buf_idx)
        // ... 其余既有端口省略
    );

    // 未使用的接线占位，避免编译期悬空告警
    wire _unused = &{1'b0, seg_sel, seg_data, HDMI_CLK_P, HDMI_D2_P, HDMI_D1_P,
                     HDMI_D0_P, HDMI_DDC_SCL, HDMI_DDC_SDA, sd_ncs, sd_dclk,
                     sd_mosi, sd_miso, fetch_row, disp_row, xfd_busy_mem,
                     vs_tgl_pulse, line_tgl_pulse, new_dob, video_read_en,
                     vout_data, key1, key2, key3};

endmodule

//=============================================================================
// 以下为骨架所需的占位子模块（仅端口，无逻辑）——实际工程由对应真实现替换
//=============================================================================
module sync_2ff (input wire clk, input wire rst, input wire d, output reg q);
    reg q0;
    always @(posedge clk or posedge rst) begin
        if (rst) begin q0 <= 1'b0; q <= 1'b0; end
        else     begin q0 <= d;    q <= q0;   end
    end
endmodule

module blackbox_video_timing_data (
    input wire video_clk, rst, xfd_en,
    output wire read_req, input wire read_req_ack,
    output wire hs, vs, de
); endmodule

module blackbox_video_delay (
    input wire video_clk, rst, read_en, input wire [23:0] read_data,
    input wire hs, vs, de,
    output wire hs_r, vs_r, de_r, output wire [23:0] vout_data
); endmodule

module blackbox_frame_read_write (input wire mem_clk, rst, read_clk, read_req, output wire read_req_ack); endmodule

module blackbox_brightness_ctrl (input wire clk, rst, de, key, input wire [23:0] rgb_in, output wire [23:0] rgb_out, output wire [7:0] brightness_val); endmodule

module blackbox_osd_overlay (input wire clk, rst, hs, vs, de, input wire [23:0] rgb_in, output wire [23:0] rgb_out); endmodule

module blackbox_sdram (input wire Clk, Rst, App_rd_en, output wire Sdr_rd_en); endmodule

module blackbox_sd_card_bmp (input wire clk, rst, key_next, key_auto, xfd_busy, output wire [1:0] write_buf_idx, disp_buf_idx); endmodule
