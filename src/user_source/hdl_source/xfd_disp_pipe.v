//============================================================================
// 模块: xfd_disp_pipe
// 功能: 图片切换淡入淡出转场 - 行缓存读 + 2 级 Alpha 混合流水线
//
// 延迟结构:
//   x 计数器提前到 de_d[17]
//   -> BRAM 在 de_d[18] 给出像素
//   -> S1: 乘法结果寄存器 (de_d[18] 使能)
//   -> S2: 加法/移位输出寄存器 (de_d[19] 使能)
//   -> de_d[20] 输出有效
//   总延迟仍为 LAT=20，与 video_delay 对齐
//
// 时钟域: video_clk = 25MHz
//============================================================================

`timescale 1ns / 1ps

module xfd_disp_pipe #(
    parameter LINE_LEN = 640,
    parameter LAT      = 20
)(
    input  wire        video_clk,
    input  wire        rst,
    input  wire        xfd_en,
    input  wire [8:0]  alpha,       // 0..256
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        de_in,
    output wire        rd_page,
    output wire [9:0]  rd_addr,
    input  wire [31:0] old_dob,
    input  wire [31:0] new_dob,
    output wire        hs_out,
    output wire        vs_out,
    output wire        de_out,
    output wire [23:0] rgb_out,
    output wire [9:0]  disp_row
);

    localparam [9:0] COL_LAST = LINE_LEN - 1;

    //==========================================================================
    // 时序延时链（保持 LAT=20）
    //==========================================================================
    reg [LAT:0] hs_d;
    reg [LAT:0] vs_d;
    reg [LAT:0] de_d;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            hs_d <= {(LAT+1){1'b0}};
            vs_d <= {(LAT+1){1'b0}};
            de_d <= {(LAT+1){1'b0}};
        end else begin
            hs_d <= {hs_d[LAT-1:0], hs_in};
            vs_d <= {vs_d[LAT-1:0], vs_in};
            de_d <= {de_d[LAT-1:0], de_in};
        end
    end

    assign hs_out = hs_d[LAT];
    assign vs_out = vs_d[LAT];
    assign de_out = de_d[LAT];

    //==========================================================================
    // 像素计数器
    //   提前一拍：de_d[17] 计数，BRAM 在 de_d[18] 出数
    //   地址限制在 0..639，避免读到行外
    //==========================================================================
    reg [9:0] x;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            x <= 10'd0;
        end else if (de_d[17]) begin
            if (x == COL_LAST)
                x <= 10'd0;
            else
                x <= x + 1'b1;
        end else begin
            x <= 10'd0;
        end
    end

    assign rd_addr = x;

    //==========================================================================
    // 页选择 / 显示行号
    //==========================================================================
    reg  [9:0] page;
    reg  [9:0] row;
    reg        vs_d1;

    always @(posedge video_clk or posedge rst) begin
        if (rst)
            vs_d1 <= 1'b0;
        else
            vs_d1 <= vs_in;
    end

    wire vs_rise     = vs_in & ~vs_d1;
    wire de_out_fall = ~de_d[LAT] & de_d[LAT-1];

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            page <= 1'b0;
        end else if (vs_rise) begin
            page <= 1'b0;
        end else if (de_out_fall) begin
            page <= ~page;
        end
    end

    assign rd_page = page;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            row <= 10'd0;
        end else if (vs_rise) begin
            row <= 10'd0;
        end else if (de_out_fall) begin
            row <= row + 10'd1;
        end
    end

    assign disp_row = row;

    //==========================================================================
    // Alpha 混合：两级流水
    //   out = (old*(256-alpha) + new*alpha) >> 8
    //
    //   old/new 8bit，alpha/alpha_inv 9bit
    //   乘积 18bit，和 19bit
    //==========================================================================
    wire [8:0] alpha_inv = 9'd256 - alpha;

    wire [8:0] old_r = {1'b0, old_dob[31:24]};
    wire [8:0] old_g = {1'b0, old_dob[23:16]};
    wire [8:0] old_b = {1'b0, old_dob[15:8]};

    wire [8:0] new_r = {1'b0, new_dob[31:24]};
    wire [8:0] new_g = {1'b0, new_dob[23:16]};
    wire [8:0] new_b = {1'b0, new_dob[15:8]};

    // 乘法（组合）
    wire [17:0] mix_old_r = old_r * alpha_inv;
    wire [17:0] mix_old_g = old_g * alpha_inv;
    wire [17:0] mix_old_b = old_b * alpha_inv;

    wire [17:0] mix_new_r = new_r * alpha;
    wire [17:0] mix_new_g = new_g * alpha;
    wire [17:0] mix_new_b = new_b * alpha;

    //--------------------------------------------------------------------------
    // S1: 乘法结果打一拍
    //   注意：de_d[18] 为低时必须“保持”而不是清零。
    //   最后一个像素的乘积在 de_d[18] 的最后一拍写入，
    //   下一拍 de_d[19] 还要用它做加法。
    //--------------------------------------------------------------------------
    reg [17:0] mix_old_r_1;
    reg [17:0] mix_old_g_1;
    reg [17:0] mix_old_b_1;
    reg [17:0] mix_new_r_1;
    reg [17:0] mix_new_g_1;
    reg [17:0] mix_new_b_1;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            mix_old_r_1 <= 18'd0;
            mix_old_g_1 <= 18'd0;
            mix_old_b_1 <= 18'd0;
            mix_new_r_1 <= 18'd0;
            mix_new_g_1 <= 18'd0;
            mix_new_b_1 <= 18'd0;
        end else if (de_d[18]) begin
            mix_old_r_1 <= mix_old_r;
            mix_old_g_1 <= mix_old_g;
            mix_old_b_1 <= mix_old_b;
            mix_new_r_1 <= mix_new_r;
            mix_new_g_1 <= mix_new_g;
            mix_new_b_1 <= mix_new_b;
        end
        // else: 保持，保证最后一个像素能进入 S2
    end

    //--------------------------------------------------------------------------
    // S2: 加法 + 移位 + 输出寄存
    //--------------------------------------------------------------------------
    wire [18:0] mix_sum_r = {1'b0, mix_old_r_1} + {1'b0, mix_new_r_1};
    wire [18:0] mix_sum_g = {1'b0, mix_old_g_1} + {1'b0, mix_new_g_1};
    wire [18:0] mix_sum_b = {1'b0, mix_old_b_1} + {1'b0, mix_new_b_1};

    wire [7:0] blend_r = mix_sum_r[15:8];
    wire [7:0] blend_g = mix_sum_g[15:8];
    wire [7:0] blend_b = mix_sum_b[15:8];

    reg [23:0] rgb_r;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            rgb_r <= 24'd0;
        end else if (de_d[19]) begin
            rgb_r <= {blend_r, blend_g, blend_b};
        end else begin
            rgb_r <= 24'd0;
        end
    end

    assign rgb_out = rgb_r;

endmodule