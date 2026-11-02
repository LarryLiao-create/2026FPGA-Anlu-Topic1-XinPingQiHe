module hdmi_audio_tone_i2s_64fs #(
    parameter [31:0] PHASE_INC = 32'd39370534,   // 仅为兼容旧顶层，本版内部不使用
    parameter signed [23:0] AMP = 24'sd2000000,  // 仅为兼容旧顶层（正弦表峰值已按 2e6 标定）
    parameter integer NOTE_HOLD_FRAMES = 14400,  // 每拍 0.3s @ 48kHz（16bit 计数器可到 1.36s）
    parameter signed [23:0] BEEP_AMP = 24'sd2000000
)(
    input  wire I_mclk,          // 12.288MHz
    input  wire I_rst,           // 高有效异步复位
    input  wire trigger_beep,    // 叫号提示音触发
    output reg  O_i2s_BCLK,
    output reg  O_i2s_LRCK,
    output reg  O_i2s_DOUT
);

//============================================================================
// 提示音状态机
//============================================================================
localparam [1:0] ST_IDLE      = 2'd0;
localparam [1:0] ST_BEEP_DING = 2'd1;  // 880Hz, 0.15s
localparam [1:0] ST_BEEP_DONG = 2'd2;  // 440Hz, 0.3s

localparam [31:0] DING_PHASE_INC = 32'd78741068;  // 880Hz @ 48kHz
localparam [31:0] DONG_PHASE_INC = 32'd39370534;  // 440Hz @ 48kHz
localparam [13:0] DING_FRAMES    = 14'd12000;     // 0.15s @ 48kHz
localparam [13:0] DONG_FRAMES    = 14'd24000;     // 0.3s  @ 48kHz

reg [1:0]  S_beep_state;
reg [13:0] S_beep_frame_cnt;
reg [31:0] S_beep_phase_acc;

//============================================================================
// trigger_beep 同步 / 边沿检测 / 锁存
//============================================================================
(* ASYNC_REG = "TRUE" *) reg [1:0] S_trig_meta;   // 2 级同步
reg [17:0] S_trig_cnt;                            // 10ms 消抖
reg        S_trig_stable;
reg        S_trig_stable_d;
reg        beep_req;

wire sw1_level  = S_trig_meta[1];
wire W_edge_det = S_trig_stable & ~S_trig_stable_d;

//============================================================================
// 1) 16 步旋律 ROM —— 每个地址存一个音符的 32bit 频率控制字
//    inc = f / 48000 * 2^32
//    曲目：欢乐颂前两句   E E F G | G F E D | C C D E | E D D D
//============================================================================
function [31:0] melody_inc;
    input [3:0] idx;
    begin
        case (idx)
            4'd0 : melody_inc = 32'd29494578;   // E4  329.63Hz
            4'd1 : melody_inc = 32'd29494578;   // E4
            4'd2 : melody_inc = 32'd31248410;   // F4  349.23Hz
            4'd3 : melody_inc = 32'd35075155;   // G4  392.00Hz
            4'd4 : melody_inc = 32'd35075155;   // G4
            4'd5 : melody_inc = 32'd31248410;   // F4
            4'd6 : melody_inc = 32'd29494578;   // E4
            4'd7 : melody_inc = 32'd26276681;   // D4  293.66Hz
            4'd8 : melody_inc = 32'd23409862;   // C4  261.63Hz
            4'd9 : melody_inc = 32'd23409862;   // C4
            4'd10: melody_inc = 32'd26276681;   // D4
            4'd11: melody_inc = 32'd29494578;   // E4
            4'd12: melody_inc = 32'd29494578;   // E4
            4'd13: melody_inc = 32'd26276681;   // D4
            4'd14: melody_inc = 32'd26276681;   // D4
            default: melody_inc = 32'd26276681; // D4
        endcase
    end
endfunction

//============================================================================
// 2) 64 点正弦查找表（峰值 2,000,000，全部在 24bit 有符号范围内）
//    value(n) = 2,000,000 * sin(2*pi*n/64)
//============================================================================
function signed [23:0] sine_lut;
    input [5:0] phase;      // 取相位累加器高 6 位
    begin
        case (phase)
            6'd0 : sine_lut =  24'sd0;
            6'd1 : sine_lut =  24'sd196000;
            6'd2 : sine_lut =  24'sd390000;
            6'd3 : sine_lut =  24'sd580000;
            6'd4 : sine_lut =  24'sd765000;
            6'd5 : sine_lut =  24'sd942000;
            6'd6 : sine_lut =  24'sd1111000;
            6'd7 : sine_lut =  24'sd1268000;
            6'd8 : sine_lut =  24'sd1414000;
            6'd9 : sine_lut =  24'sd1546000;
            6'd10: sine_lut =  24'sd1662000;
            6'd11: sine_lut =  24'sd1763000;
            6'd12: sine_lut =  24'sd1847000;
            6'd13: sine_lut =  24'sd1913000;
            6'd14: sine_lut =  24'sd1961000;
            6'd15: sine_lut =  24'sd1990000;
            6'd16: sine_lut =  24'sd2000000;
            6'd17: sine_lut =  24'sd1990000;
            6'd18: sine_lut =  24'sd1961000;
            6'd19: sine_lut =  24'sd1913000;
            6'd20: sine_lut =  24'sd1847000;
            6'd21: sine_lut =  24'sd1763000;
            6'd22: sine_lut =  24'sd1662000;
            6'd23: sine_lut =  24'sd1546000;
            6'd24: sine_lut =  24'sd1414000;
            6'd25: sine_lut =  24'sd1268000;
            6'd26: sine_lut =  24'sd1111000;
            6'd27: sine_lut =  24'sd942000;
            6'd28: sine_lut =  24'sd765000;
            6'd29: sine_lut =  24'sd580000;
            6'd30: sine_lut =  24'sd390000;
            6'd31: sine_lut =  24'sd196000;
            6'd32: sine_lut =  24'sd0;
            6'd33: sine_lut = -24'sd196000;
            6'd34: sine_lut = -24'sd390000;
            6'd35: sine_lut = -24'sd580000;
            6'd36: sine_lut = -24'sd765000;
            6'd37: sine_lut = -24'sd942000;
            6'd38: sine_lut = -24'sd1111000;
            6'd39: sine_lut = -24'sd1268000;
            6'd40: sine_lut = -24'sd1414000;
            6'd41: sine_lut = -24'sd1546000;
            6'd42: sine_lut = -24'sd1662000;
            6'd43: sine_lut = -24'sd1763000;
            6'd44: sine_lut = -24'sd1847000;
            6'd45: sine_lut = -24'sd1913000;
            6'd46: sine_lut = -24'sd1961000;
            6'd47: sine_lut = -24'sd1990000;
            6'd48: sine_lut = -24'sd2000000;
            6'd49: sine_lut = -24'sd1990000;
            6'd50: sine_lut = -24'sd1961000;
            6'd51: sine_lut = -24'sd1913000;
            6'd52: sine_lut = -24'sd1847000;
            6'd53: sine_lut = -24'sd1763000;
            6'd54: sine_lut = -24'sd1662000;
            6'd55: sine_lut = -24'sd1546000;
            6'd56: sine_lut = -24'sd1414000;
            6'd57: sine_lut = -24'sd1268000;
            6'd58: sine_lut = -24'sd1111000;
            6'd59: sine_lut = -24'sd942000;
            6'd60: sine_lut = -24'sd765000;
            6'd61: sine_lut = -24'sd580000;
            6'd62: sine_lut = -24'sd390000;
            default: sine_lut = -24'sd196000;
        endcase
    end
endfunction

//============================================================================
// 3) 寄存器
//============================================================================
reg  [5:0]  S_bit_cnt;
reg  [63:0] S_shift_reg;
reg  [31:0] S_phase_acc;
reg signed [23:0] S_sample_word;
reg signed [23:0] S_sample_next;
reg  [3:0]  S_note_idx;          // ★ 4bit：0..15
reg [15:0]  S_note_frame_cnt;    // 节拍计数器（0..NOTE_HOLD_FRAMES-1）

wire [31:0] W_note_inc = melody_inc(S_note_idx);

//============================================================================
// 4) 组合逻辑：决定本帧要发送的样本与下一状态
//    默认 = 背景旋律；只有提示音状态机明确要发声时才覆盖
//============================================================================
reg signed [23:0] W_frame_sample;
reg [1:0]         W_state_next;
reg [13:0]        W_cnt_next;
reg [31:0]        W_phase_next;

always @(*) begin
    // 默认：背景旋律，提示音状态保持
    W_frame_sample = S_sample_next;
    W_state_next   = S_beep_state;
    W_cnt_next     = S_beep_frame_cnt;
    W_phase_next   = S_beep_phase_acc;

    case (S_beep_state)
        ST_IDLE: begin
            if (beep_req) begin
                W_state_next = ST_BEEP_DING;
                W_cnt_next   = 14'd1;
                W_phase_next = 32'h8000_0000;   // 半周相位，起始样本为 0，防爆音
            end
        end

        ST_BEEP_DING: begin
            W_frame_sample = sine_lut(S_beep_phase_acc[31:26]);

            // 阶梯包络衰减
            if (S_beep_frame_cnt < (DING_FRAMES >> 2)) begin
            end else if (S_beep_frame_cnt < (DING_FRAMES >> 1)) begin
                W_frame_sample = W_frame_sample >> 1;
            end else if (S_beep_frame_cnt < ((DING_FRAMES >> 2) * 3)) begin
                W_frame_sample = W_frame_sample >> 2;
            end else begin
                W_frame_sample = W_frame_sample >> 3;
            end

            W_phase_next = S_beep_phase_acc + DING_PHASE_INC;

            if (S_beep_frame_cnt >= DING_FRAMES) begin
                W_state_next   = ST_BEEP_DONG;
                W_cnt_next     = 14'd1;
                W_phase_next   = 32'h8000_0000;
                W_frame_sample = 24'sd0;        // 切换静音一帧，防爆音
            end else begin
                W_cnt_next = S_beep_frame_cnt + 14'd1;
            end
        end

        ST_BEEP_DONG: begin
            W_frame_sample = sine_lut(S_beep_phase_acc[31:26]);

            if (S_beep_frame_cnt < (DONG_FRAMES >> 2)) begin
            end else if (S_beep_frame_cnt < (DONG_FRAMES >> 1)) begin
                W_frame_sample = W_frame_sample >> 1;
            end else if (S_beep_frame_cnt < ((DONG_FRAMES >> 2) * 3)) begin
                W_frame_sample = W_frame_sample >> 2;
            end else begin
                W_frame_sample = W_frame_sample >> 3;
            end

            W_phase_next = S_beep_phase_acc + DONG_PHASE_INC;

            if (S_beep_frame_cnt >= DONG_FRAMES) begin
                W_state_next   = ST_IDLE;
                W_cnt_next     = 14'd0;
                W_phase_next   = 32'd0;
                W_frame_sample = S_sample_next; // 恢复背景旋律
            end else begin
                W_cnt_next = S_beep_frame_cnt + 14'd1;
            end
        end

        default: begin
            W_state_next   = ST_IDLE;
            W_frame_sample = S_sample_next;
        end
    endcase
end

//============================================================================
// 5) I2S 发送 + 旋律调度
//    I_mclk 12.288MHz -> BCLK 6.144MHz -> 每声道 64bit -> LRCK 48kHz
//============================================================================
always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        O_i2s_BCLK       <= 1'b0;
        O_i2s_LRCK       <= 1'b0;
        O_i2s_DOUT       <= 1'b0;
        S_bit_cnt        <= 6'd0;
        S_shift_reg      <= 64'd0;
        S_phase_acc      <= 32'd0;
        S_sample_word    <= 24'sd0;
        S_sample_next    <= 24'sd0;
        S_note_idx       <= 4'd0;
        S_note_frame_cnt <= 16'd0;
        S_beep_state     <= ST_IDLE;
        S_beep_frame_cnt <= 14'd0;
        S_beep_phase_acc <= 32'd0;
        S_trig_meta      <= 2'b00;
        S_trig_cnt       <= 18'd0;
        S_trig_stable    <= 1'b0;
        S_trig_stable_d  <= 1'b0;
        beep_req         <= 1'b0;
    end else begin
        // ---------------- 触发同步与边沿检测 ----------------
        S_trig_meta <= {S_trig_meta[0], trigger_beep};

        if (sw1_level != S_trig_stable) begin
            if (S_trig_cnt >= 18'd249_999) begin   // 25MHz 下 10ms
                S_trig_cnt    <= 18'd0;
                S_trig_stable <= sw1_level;
            end else begin
                S_trig_cnt <= S_trig_cnt + 1'b1;
            end
        end else begin
            S_trig_cnt <= 18'd0;
        end

        S_trig_stable_d <= S_trig_stable;

        if (W_edge_det && (S_beep_state == ST_IDLE)) begin
            beep_req <= 1'b1;
        end

        // ---------------- BCLK ----------------
        O_i2s_BCLK <= ~O_i2s_BCLK;

        if (O_i2s_BCLK == 1'b1) begin
            O_i2s_DOUT  <= S_shift_reg[63];
            S_shift_reg <= {S_shift_reg[62:0], 1'b0};

            if (S_bit_cnt == 6'd63) begin
                S_bit_cnt <= 6'd0;

                if (O_i2s_LRCK == 1'b0) begin
                    // 左声道发送完毕 -> 切到右声道（同一份样本）
                    O_i2s_LRCK  <= 1'b1;
                    S_shift_reg <= {S_sample_word[23:0], 40'd0};
                end else begin
                    // 右声道发送完毕 -> 换帧：算下一个样本 + 更新节拍
                    O_i2s_LRCK <= 1'b0;

                    // ---- 背景旋律：相位连续累加 + 正弦查表 ----
                    S_phase_acc   <= S_phase_acc + W_note_inc;
                    S_sample_next <= sine_lut(S_phase_acc[31:26]);

                    // ---- 节拍计时：满 NOTE_HOLD_FRAMES 帧就换下一个音符 ----
                    if (S_note_frame_cnt == NOTE_HOLD_FRAMES - 1) begin
                        S_note_frame_cnt <= 16'd0;
                        if (S_note_idx == 4'd15)
                            S_note_idx <= 4'd0;          // 16 步循环
                        else
                            S_note_idx <= S_note_idx + 4'd1;
                    end else begin
                        S_note_frame_cnt <= S_note_frame_cnt + 16'd1;
                    end

                    // ---- 提示音状态机推进 ----
                    S_beep_state     <= W_state_next;
                    S_beep_frame_cnt <= W_cnt_next;
                    S_beep_phase_acc <= W_phase_next;

                    // ---- 本帧真正发送的样本 ----
                    S_sample_word    <= W_frame_sample;
                    S_shift_reg      <= {W_frame_sample[23:0], 40'd0};

                    if ((S_beep_state == ST_IDLE) && beep_req &&
                        (W_state_next == ST_BEEP_DING))
                        beep_req <= 1'b0;
                end
            end else begin
                S_bit_cnt <= S_bit_cnt + 6'd1;
            end
        end
    end
end

endmodule