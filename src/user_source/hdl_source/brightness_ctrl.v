module brightness_ctrl(
    input  wire        clk,
    input  wire        rst,
    input  wire        de,
    input  wire        key,              // 亮度切换按键（KEY3）
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out,
    output reg  [7:0]  brightness_val
);

    // =========================================================
    // 1. 按键消抖 + 边沿检测
    // =========================================================
    reg key_d0, key_d1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            key_d0 <= 1'b0;
            key_d1 <= 1'b0;
        end else begin
            key_d0 <= key;
            key_d1 <= key_d0;
        end
    end

    wire key_press = key_d0 & ~key_d1;    // 按键上升沿

    // =========================================================
    // 2. 亮度档位（8档）
    // =========================================================
    reg [2:0] level;    // 0~7，对应8档

    always @(posedge clk or posedge rst) begin
        if (rst)
            level <= 3'd0;
        else if (key_press)
            level <= level + 1'b1;    // 自动回绕 0→1→...→7→0
    end

    // 8档亮度值
    always @(*) begin
        case (level)
            3'd0: brightness_val = 8'd0;
            3'd1: brightness_val = 8'd32;
            3'd2: brightness_val = 8'd64;
            3'd3: brightness_val = 8'd96;
            3'd4: brightness_val = 8'd128;   // 默认档
            3'd5: brightness_val = 8'd160;
            3'd6: brightness_val = 8'd192;
            3'd7: brightness_val = 8'd255;
            default: brightness_val = 8'd128;
        endcase
    end

    // =========================================================
    // 3. 亮度调节：RGB 加上偏移量
    // =========================================================
wire signed [9:0] offset = brightness_val - 8'd128;

wire [7:0] r_raw = rgb_in[23:16];
wire [7:0] g_raw = rgb_in[15:8];
wire [7:0] b_raw = rgb_in[7:0];

// 先把 r_raw 扩展成 10 位有符号数（高位补 0）
wire signed [9:0] r_raw_s = {2'b00, r_raw};
wire signed [9:0] g_raw_s = {2'b00, g_raw};
wire signed [9:0] b_raw_s = {2'b00, b_raw};

// 相加（10位有符号 + 10位有符号 = 10位有符号，够用）
wire signed [9:0] r_adj = r_raw_s + offset;
wire signed [9:0] g_adj = g_raw_s + offset;
wire signed [9:0] b_adj = b_raw_s + offset;

// 钳位
wire [7:0] r_out = (r_adj < 0) ? 8'd0 : (r_adj > 255) ? 8'd255 : r_adj[7:0];
wire [7:0] g_out = (g_adj < 0) ? 8'd0 : (g_adj > 255) ? 8'd255 : g_adj[7:0];
wire [7:0] b_out = (b_adj < 0) ? 8'd0 : (b_adj > 255) ? 8'd255 : b_adj[7:0];

    assign rgb_out = {r_out, g_out, b_out};

endmodule