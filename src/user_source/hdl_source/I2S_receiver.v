`timescale 1ns / 1ps

module I2S_receiver (
    input  wire       I_clk,
    input  wire       I_rst,

    input  wire       I_i2s_BCLK,
    input  wire       I_i2s_LRCK,
    input  wire       I_i2s_DOUT,

    output reg        O_audio_valid,
    output reg [23:0] O_audio_left_data,
    output reg [23:0] O_audio_right_data
);

    //------------------------------------------------------------------
    // BCLK: 2FF 同步 + 1 级延迟
    //------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg S_i2s_bclk_1d;
    (* ASYNC_REG = "TRUE" *) reg S_i2s_bclk_2d;
    reg                         S_i2s_bclk_3d;
    wire                        S_i2s_bclk_p_edge;

    //------------------------------------------------------------------
    // LRCK: 2FF 同步 + 1 级延迟
    //------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg S_i2s_lrck_1d;
    (* ASYNC_REG = "TRUE" *) reg S_i2s_lrck_2d;
    reg                         S_i2s_lrck_3d;
    reg                         S_i2s_lrck_sync;
    wire                        S_i2s_lrck_p_edge;
    wire                        S_i2s_lrck_n_edge;

    //------------------------------------------------------------------
    // DOUT: 2FF 同步 + 1 级延迟
    //------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg S_i2s_dout_1d;
    (* ASYNC_REG = "TRUE" *) reg S_i2s_dout_2d;
    reg                         S_i2s_dout_3d;

    //------------------------------------------------------------------
    // 数据移位与锁存
    //------------------------------------------------------------------
    reg [63:0] S_left_shift_data;
    reg [63:0] S_right_shift_data;

    reg        S_left_data_valid;
    reg        S_right_data_valid;

    reg [63:0] S_left_data_lock;

    //------------------------------------------------------------------
    // 3 级同步链
    //------------------------------------------------------------------
    always @(posedge I_clk) begin
        S_i2s_bclk_1d <= I_i2s_BCLK;
        S_i2s_bclk_2d <= S_i2s_bclk_1d;
        S_i2s_bclk_3d <= S_i2s_bclk_2d;

        S_i2s_lrck_1d <= I_i2s_LRCK;
        S_i2s_lrck_2d <= S_i2s_lrck_1d;
        S_i2s_lrck_3d <= S_i2s_lrck_2d;

        S_i2s_dout_1d <= I_i2s_DOUT;
        S_i2s_dout_2d <= S_i2s_dout_1d;
        S_i2s_dout_3d <= S_i2s_dout_2d;
    end

    //------------------------------------------------------------------
    // BCLK 上升沿检测
    //------------------------------------------------------------------
    assign S_i2s_bclk_p_edge = ~S_i2s_bclk_3d & S_i2s_bclk_2d;

    //------------------------------------------------------------------
    // 在 BCLK 上升沿锁存 LRCK
    //------------------------------------------------------------------
    always @(posedge I_clk) begin
        if (S_i2s_bclk_p_edge)
            S_i2s_lrck_sync <= S_i2s_lrck_3d;
        else
            S_i2s_lrck_sync <= S_i2s_lrck_sync;
    end

    assign S_i2s_lrck_p_edge = ~S_i2s_lrck_sync & S_i2s_lrck_3d;
    assign S_i2s_lrck_n_edge = ~S_i2s_lrck_3d & S_i2s_lrck_sync;

    //------------------------------------------------------------------
    // 左右声道移位
    //------------------------------------------------------------------
    always @(posedge I_clk) begin
        if (S_i2s_bclk_p_edge)
            if (S_i2s_lrck_sync)
                begin
                    S_right_shift_data <= {S_right_shift_data[62:0], S_i2s_dout_3d};
                    S_left_shift_data  <= 'd0;
                end
            else
                begin
                    S_right_shift_data <= 'd0;
                    S_left_shift_data  <= {S_left_shift_data[62:0], S_i2s_dout_3d};
                end
        else
            begin
                S_right_shift_data <= S_right_shift_data;
                S_left_shift_data  <= S_left_shift_data;
            end
    end

    //------------------------------------------------------------------
    // 声道数据有效脉冲
    //------------------------------------------------------------------
    always @(posedge I_clk) begin
        if (S_i2s_bclk_p_edge && S_i2s_lrck_p_edge)
            S_left_data_valid <= 1'b1;
        else
            S_left_data_valid <= 1'b0;
    end

    always @(posedge I_clk) begin
        if (S_i2s_bclk_p_edge && S_i2s_lrck_n_edge)
            S_right_data_valid <= 1'b1;
        else
            S_right_data_valid <= 1'b0;
    end

    //------------------------------------------------------------------
    // 左声道数据锁存
    //------------------------------------------------------------------
    always @(posedge I_clk) begin
        if (S_left_data_valid)
            S_left_data_lock <= S_left_shift_data;
        else
            S_left_data_lock <= S_left_data_lock;
    end

    //------------------------------------------------------------------
    // 输出寄存器
    //------------------------------------------------------------------
    always @(posedge I_clk) begin
        if (S_right_data_valid)
            begin
                O_audio_valid      <= 1'b1;
                O_audio_left_data  <= S_left_data_lock[63:40];
                O_audio_right_data <= S_right_shift_data[63:40];
            end
        else
            begin
                O_audio_valid      <= 1'b0;
                O_audio_left_data  <= 'd0;
                O_audio_right_data <= 'd0;
            end
    end

endmodule