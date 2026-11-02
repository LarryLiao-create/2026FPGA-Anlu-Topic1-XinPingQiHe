
`timescale 1ns / 1ps

module xfd_ctrl #(
    parameter ALPHA_STEP = 4,
    parameter integer HOLD_FRAMES = 8  
)(
    input  wire       video_clk, 
    input  wire       rst,         
    input  wire [1:0] disp_buf_idx,
    input  wire       vs_in,        
    input  wire       de_in,       
    output reg        xfd_en,      
    output reg        xfd_busy,    
    output reg  [8:0] alpha,      
    output reg  [1:0] old_idx,     
    output reg  [1:0] new_idx,     
    output reg        vs_tgl,      
    output reg        line_tgl     
);


// 1. disp_buf_idx 同步器：从 sd_card_clk 域同步到 video_clk 域
    reg [1:0] disp_sync_s1;  
    reg [1:0] disp_sync;      

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            disp_sync_s1 <= 2'b00;
            disp_sync    <= 2'b00;
        end else begin
            disp_sync_s1 <= disp_buf_idx;
            disp_sync    <= disp_sync_s1;
        end
    end

// 2. vs_in / de_in 打一拍，用于上升沿检测
    reg vs_d;   
    reg de_d;   

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            vs_d <= 1'b0;
            de_d <= 1'b0;
        end else begin
            vs_d <= vs_in;
            de_d <= de_in;
        end
    end

// 帧起始脉冲：vs_in 上升沿
    wire vs_rise = vs_in & ~vs_d;

// 行起始脉冲：de_in 上升沿
    wire de_rise = de_in & ~de_d;

// 3. toggle 输出
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            vs_tgl   <= 1'b0;
            line_tgl <= 1'b0;
        end else begin
            // 帧起始：vs_tgl 翻转
            if (vs_rise)
                vs_tgl <= ~vs_tgl;
            // 行起始：line_tgl 翻转
            if (de_rise)
                line_tgl <= ~line_tgl;
        end
    end

// 4. 转场状态机与 alpha 斜坡
    reg [1:0] prev_disp;
    reg [7:0] hold_cnt;
    reg       ph_hold;                         
    localparam [7:0] HOLD_N = HOLD_FRAMES;

    wire [9:0] alpha_next = {1'b0, alpha} + ALPHA_STEP[9:0];

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            prev_disp <= 2'd0;
            xfd_en    <= 1'b0;
            xfd_busy  <= 1'b0;
            ph_hold   <= 1'b0; 
            alpha     <= 9'd0;
            hold_cnt  <= 8'd0;
            old_idx   <= 2'd0;
            new_idx   <= 2'd0;
                end else if (vs_rise) begin
            if (xfd_en) begin
                if (!ph_hold) begin
                    if (alpha_next >= 10'd256) begin
                        alpha    <= 9'd256;
                        ph_hold  <= 1'b1;    
                        hold_cnt <= 8'd0;
                    end else begin
                        alpha    <= alpha_next[8:0];
                    end
                end
                else begin
                    if (hold_cnt >= HOLD_N) begin
                        xfd_en    <= 1'b0;     
                        xfd_busy  <= 1'b0;
                        prev_disp <= new_idx;
                        ph_hold   <= 1'b0;
                        hold_cnt  <= 8'd0;
                    end else begin
                        hold_cnt  <= hold_cnt + 8'd1;
                    end
                end
            end
            else begin
                ph_hold  <= 1'b0;
                hold_cnt <= 8'd0;
                alpha    <= 9'd0;
                if (disp_sync != prev_disp) begin 
                    xfd_en   <= 1'b1;
                    xfd_busy <= 1'b1;
                    old_idx  <= prev_disp;        
                    new_idx  <= disp_sync;         
                end
            end
        end
    end

endmodule
