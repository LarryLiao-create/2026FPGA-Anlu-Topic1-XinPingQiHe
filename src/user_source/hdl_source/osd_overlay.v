`timescale 1ns / 1ps
module osd_overlay #(
    parameter H_ACTIVE    = 640,          // 一行有效像素数
    parameter V_ACTIVE    = 480,          // 一帧有效行数
    parameter BAND_TOP    = 450,          // 字幕带首行
    parameter BAND_BOTTOM = 465,          // 字幕带末行
    parameter TEXT_W      = 336,          // 字幕点阵总宽 
    parameter NCHAR       = 44,           // 字符格数
    parameter CELL        = 16,           // 字高/字宽
    parameter SCROLL_SPAN = 976,         
    parameter HS_POL      = 1'b0,         // 行同步极性
    parameter VS_POL      = 1'b0,         // 场同步极性
    parameter [23:0] TEXT_COLOR = 24'h000000,   
    parameter [23:0] BG_COLOR   = 24'hADD8E6,   
    parameter [9:0] QUEUE_TOP  = 10'd420,     // 叫号牌的起始行
    parameter [9:0] QUEUE_LEFT = 10'd100,     // 起始列
    parameter [23:0] QUEUE_BG_COLOR = 24'hFFFACD, // 鹅黄色背景
    parameter TS_TOP    = 10,
    parameter TS_LEFT   = 450,
    parameter [23:0] TS_COLOR = 24'h00FFFF,
    parameter [9:0]BRT_TOP    = 10,      // 亮度显示起始行
    parameter [9:0]BRT_LEFT   = 10,      // 亮度显示起始列
    parameter [23:0] BRT_COLOR = 24'h00FFFF,  
    parameter integer WAVE_TOP   = 150,       
    parameter integer WAVE_BOT   = 330,       
    parameter [9:0]   WAVE_MID   = 10'd240,   
    parameter integer WAVE_DIV   = 4,         
    parameter [9:0]   WAVE_MAX   = 10'd80,     
    parameter [9:0]   WAVE_HW    = 10'd1,     
    parameter [23:0]  WAVE_COLOR = 24'h00FFFF 
) (
    input  wire  sw1,
    input  wire  sw2,
    input  wire  sw3,
    input  wire  sw4,
    input  wire [7:0]  audio_data,
    input  wire        audio_valid,     
    input  wire [7:0]  brightness_val,   
    input  wire        clk,       // 像素时钟
    input  wire        rst,       // 复位
    input  wire        hs,        // 行同步
    input  wire        vs,        // 场同步
    input  wire        de,       
    input  wire [23:0] rgb_in,    
    output reg  [23:0] rgb_out    
);

  // 同步信号极性归一化
    wire hs_active = HS_POL ? hs : ~hs;  
    wire vs_active = VS_POL ? vs : ~vs;   

    reg de_d;
    always @(posedge clk or posedge rst) begin
        if (rst)
            de_d <= 1'b0;
        else
            de_d <= de;
    end

    reg [9:0] x_cnt;
    always @(posedge clk or posedge rst) begin
        if (rst)
            x_cnt <= 10'd0;
        else if (de)
            x_cnt <= x_cnt + 10'd1;
        else
            x_cnt <= 10'd0;
    end

    reg [9:0] y_cnt;
    wire de_fall = de_d & ~de; 

    always @(posedge clk or posedge rst) begin
        if (rst)
            y_cnt <= 10'd0;
        else if (vs_active)
            y_cnt <= 10'd0;         
        else if (de_fall) begin
            if (y_cnt == V_ACTIVE - 1)
                y_cnt <= 10'd0;     
            else
                y_cnt <= y_cnt + 10'd1;
        end
    end

reg vs_d;
    always @(posedge clk or posedge rst) begin
        if (rst)
            vs_d <= 1'b0;
        else
            vs_d <= vs_active;
    end

wire frame_pulse = vs_active & ~vs_d;  
    
  // 时间计数器
reg [5:0]  sec_cnt;
reg [5:0]  min_cnt;
reg [4:0]  hour_cnt;
reg [15:0] frame_cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sec_cnt   <= 6'd0;
        min_cnt   <= 6'd0;
        hour_cnt  <= 5'd0;
        frame_cnt <= 16'd0;
    end else if (frame_pulse) begin
        if (frame_cnt == 16'd59) begin
            frame_cnt <= 16'd0;
            if (sec_cnt == 6'd59) begin
                sec_cnt <= 6'd0;
                if (min_cnt == 6'd59) begin
                    min_cnt <= 6'd0;
                    if (hour_cnt == 5'd23)
                        hour_cnt <= 5'd0;
                    else
                        hour_cnt <= hour_cnt + 1'b1;
                end else
                    min_cnt <= min_cnt + 1'b1;
            end else
                sec_cnt <= sec_cnt + 1'b1;
        end else
            frame_cnt <= frame_cnt + 1'b1;
    end
end


    reg [9:0] scroll_offset;
    always @(posedge clk or posedge rst) begin
        if (rst)
            scroll_offset <= 10'd0;
        else if (frame_pulse)
            scroll_offset <= (scroll_offset == SCROLL_SPAN - 1) ? 10'd0 : scroll_offset + 10'd1;
    end


 
    wire in_band = de && (y_cnt >= BAND_TOP) && (y_cnt <= BAND_BOTTOM);
    wire [11:0] v_off = {2'b0, x_cnt} + {2'b0, scroll_offset};
    wire in_text = (v_off >= H_ACTIVE) && (v_off < H_ACTIVE + TEXT_W);
    wire [11:0] v = v_off - H_ACTIVE;
    wire [4:0] ch_idx = v[8:4];
    wire [9:0] row_in_band = y_cnt - BAND_TOP;
    wire [3:0] glyph_row   = row_in_band[3:0];
    wire [9:0] rom_addr = {ch_idx, glyph_row};
    wire [3:0] col = v[3:0];
    
// 字库例化
    wire [15:0] rom_row;
    wire dot = rom_row[CELL-1-col];

    char_rom #(
        .NCHAR (NCHAR),
        .CELL  (CELL)
    ) u_char_rom (
        .addr     (rom_addr),
        .row_data (rom_row)
    );
// 时间戳字符索引
wire [3:0] ts_char_x   = (x_cnt - TS_LEFT) >> 4;   
wire [3:0] ts_char_col = (x_cnt - TS_LEFT) & 4'hF; 
wire [3:0] ts_char_row = y_cnt - TS_TOP;

reg [4:0] ts_char_idx;
always @(*) begin
    case (ts_char_x)
        4'd0: ts_char_idx = 5'd21 + hour_cnt / 10;
        4'd1: ts_char_idx = 5'd21 + hour_cnt % 10;
        4'd2: ts_char_idx = 5'd31;
        4'd3: ts_char_idx = 5'd21 + min_cnt / 10;
        4'd4: ts_char_idx = 5'd21 + min_cnt % 10;
        4'd5: ts_char_idx = 5'd31;
        4'd6: ts_char_idx = 5'd21 + sec_cnt / 10;
        4'd7: ts_char_idx = 5'd21 + sec_cnt % 10;
        default: ts_char_idx = 5'd21;
    endcase
end

wire [9:0]  ts_rom_addr = {ts_char_idx, ts_char_row};
wire [15:0] ts_rom_row;
wire ts_dot = ts_rom_row[CELL - 1 - ts_char_col];
wire in_ts_area = (y_cnt >= TS_TOP) && (y_cnt < TS_TOP + 16)
               && (x_cnt >= TS_LEFT) && (x_cnt < TS_LEFT + 128);

char_rom #(
    .NCHAR (NCHAR),
    .CELL  (CELL)
) u_ts_rom (
    .addr    (ts_rom_addr),
    .row_data(ts_rom_row)
);
// 叫号逻辑 
(* ASYNC_REG = "TRUE" *) reg [1:0] sw1_meta; 
reg [17:0] sw1_cnt;                          
reg        sw1_stable;                       
reg        sw1_stable_d;                      

reg [7:0] queue_num;     
reg [1:0] room_num;      

wire sw1_level = sw1_meta[1];

reg  [7:0] hist0, hist1, hist2;    
reg  [7:0] pending_num;               
reg  [7:0] blink_frm;                 
reg  [3:0] blink_div;                 
reg        blink_ph;                   
wire       new_call = sw1_stable & ~sw1_stable_d;   

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sw1_meta     <= 2'b00;
        sw1_cnt      <= 18'd0;
        sw1_stable   <= 1'b0;
        sw1_stable_d <= 1'b0;
        queue_num    <= 8'd1;
        room_num     <= 2'd1;
    end else begin
        sw1_meta <= {sw1_meta[0], sw1};

        // 消抖
        if (sw1_level != sw1_stable) begin
            if (sw1_cnt >= 18'd249_999) begin
                sw1_cnt      <= 18'd0;
                sw1_stable   <= sw1_level;
            end else begin
                sw1_cnt      <= sw1_cnt + 1'b1;
            end
        end else begin
            sw1_cnt <= 18'd0;
        end

        sw1_stable_d <= sw1_stable;

        // 检测上升沿
        if (sw1_stable & ~sw1_stable_d) begin
            queue_num <= (queue_num >= 8'd99) ? 8'd1 : queue_num + 1'b1;
            if (room_num == 2'd3) 
                room_num <= 2'd1;
            else                  
                room_num <= room_num + 1'b1;

          
            hist0 <= queue_num;
            hist1 <= hist0;
            hist2 <= hist1;
        end
        end
end

 // SW4 严格消抖 + 上升沿检测 
    (* ASYNC_REG = "TRUE" *) reg [1:0] sw4_meta; 
    reg [17:0] sw4_cnt;      
    reg        sw4_stable;   
    reg        sw4_stable_d; 
    wire       sw4_level = sw4_meta[1];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sw4_meta     <= 2'b00;
            sw4_cnt      <= 18'd0;
            sw4_stable   <= 1'b0;
            sw4_stable_d <= 1'b0;
        end else begin
            sw4_meta <= {sw4_meta[0], sw4};
            
            if (sw4_level != sw4_stable) begin
                if (sw4_cnt >= 18'd249_999) begin
                    sw4_cnt    <= 18'd0;
                    sw4_stable <= sw4_level;
                end else begin
                    sw4_cnt <= sw4_cnt + 1'b1;
                end
            end else begin
                sw4_cnt <= 18'd0;
            end
            
            sw4_stable_d <= sw4_stable;
        end
    end

wire sw4_rise = sw4_stable & ~sw4_stable_d;
wire blink_done = (blink_frm >= 8'd179);
wire blink_on   = blink_done | blink_ph;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        blink_frm <= 8'd179;         
        blink_div <= 4'd0;
        blink_ph  <= 1'b1;
    end else if (new_call) begin
        blink_frm <= 8'd0;          
        blink_div <= 4'd0;
        blink_ph  <= 1'b1;
    end else if (frame_pulse && !blink_done) begin
        blink_frm <= blink_frm + 8'd1;
        if (blink_div == 4'd14) begin
            blink_div <= 4'd0;
            blink_ph  <= ~blink_ph; 
        end else begin
            blink_div <= blink_div + 4'd1;
        end
    end
end

// 待叫号人数
always @(posedge clk or posedge rst) begin
    if (rst) begin
        pending_num <= 8'd8;       
    end else if (new_call) begin
        if (pending_num != 8'd0) pending_num <= pending_num - 8'd1;
    end else if (sw4_rise) begin
        if (pending_num != 8'd99) pending_num <= pending_num + 8'd1;
    end
end

// 叫号显示区域判断与字符索引
wire in_queue_area = (y_cnt >= QUEUE_TOP) && (y_cnt < QUEUE_TOP + 16)
                  && (x_cnt >= QUEUE_LEFT) && (x_cnt < QUEUE_LEFT + 256); 

wire [3:0] q_char_x   = (x_cnt - QUEUE_LEFT) >> 4; 
wire [3:0] q_char_col = (x_cnt - QUEUE_LEFT) & 4'hF;
wire [3:0] q_char_row = y_cnt - QUEUE_TOP;

wire [3:0] q_ten = (queue_num / 10) % 10;
wire [3:0] q_one = queue_num % 10;

reg [5:0] q_char_idx;
always @(*) begin
    case (q_char_x)
        4'd0:  q_char_idx = 6'd34; // 当
        4'd1:  q_char_idx = 6'd35; // 前
        4'd2:  q_char_idx = 6'd36; // 叫
        4'd3:  q_char_idx = 6'd37; // 号
        4'd4:  q_char_idx = 6'd31; // ：
        4'd5:  q_char_idx = 6'd21; //0
        4'd6:  q_char_idx = 6'd21 + q_ten; 
        4'd7:  q_char_idx = 6'd21 + q_one; 
        4'd8:  q_char_idx = 6'd0; 
        4'd9:  q_char_idx = 6'd38; // 请
        4'd10: q_char_idx = 6'd39; // 到
        4'd11: q_char_idx = 6'd40; // 诊
        4'd12: q_char_idx = 6'd41; // 室
        4'd13: q_char_idx = 6'd31; // ：
        4'd14: q_char_idx = 6'd21 + room_num; 
        default: q_char_idx = 6'd0;
    endcase
end

wire [9:0] q_rom_addr = {q_char_idx, q_char_row};
wire [15:0] q_rom_row;

wire q_is_blank = (q_char_idx == 6'd0);
wire q_dot = q_is_blank ? 1'b0 : q_rom_row[CELL - 1 - q_char_col];

char_rom #(
    .NCHAR (42),      
    .CELL  (CELL),
    .ADDR_W (10)       
) u_q_rom (
    .addr    (q_rom_addr),
    .row_data(q_rom_row)
);

// 亮度值显示
wire in_brt_area = (y_cnt >= BRT_TOP) && (y_cnt < BRT_TOP + 16)
                && (x_cnt >= BRT_LEFT) && (x_cnt < BRT_LEFT + 96);

wire [3:0] brt_char_x   = (x_cnt - BRT_LEFT) >> 4;     
wire [3:0] brt_char_col = (x_cnt - BRT_LEFT) & 4'hF;  
wire [3:0] brt_char_row = y_cnt - BRT_TOP;            

wire [3:0] brt_hundred = brightness_val / 100;        
wire [3:0] brt_ten     = (brightness_val / 10) % 10;  
wire [3:0] brt_one     = brightness_val % 10;         

reg [5:0] brt_char_idx;
always @(*) begin
    case (brt_char_x)
        4'd0: brt_char_idx = 6'd32;                 
        4'd1: brt_char_idx = 6'd33;                
        4'd2: brt_char_idx = 6'd31;                 
        4'd3: brt_char_idx = 6'd21 + brt_hundred;    
        4'd4: brt_char_idx = 6'd21 + brt_ten;        
        4'd5: brt_char_idx = 6'd21 + brt_one;       
        default: brt_char_idx = 6'd32;
    endcase
end

wire [9:0] brt_rom_addr = {brt_char_idx, brt_char_row};
wire [15:0] brt_rom_row;
wire brt_dot = brt_rom_row[CELL - 1 - brt_char_col];

char_rom #(
    .NCHAR (NCHAR),
    .CELL  (CELL)
) u_brt_rom (
    .addr    (brt_rom_addr),
    .row_data(brt_rom_row)
);

// 音频时域波形
 (* ASYNC_REG = "TRUE" *) reg [1:0] sw2_meta;
 always @(posedge clk or posedge rst) begin
     if (rst) sw2_meta <= 2'b00;
     else     sw2_meta <= {sw2_meta[0], sw2};
 end
wire wave_en = sw2_meta[1];

 // 降采样
wire        wave_last = (adec_cnt == WAVE_DIV - 1);
wire        wave_wr   = audio_valid && wave_en && wave_last;  

reg  [7:0]  adec_cnt;        
reg  [9:0]  wave_wp;         
reg  [9:0]  wave_fill;     

 always @(posedge clk or posedge rst) begin
     if (rst) begin
         adec_cnt  <= 8'd0;
         wave_wp   <= 10'd0;
         wave_fill <= 10'd0;
     end else if (audio_valid && wave_en) begin
         if (wave_last) begin
             adec_cnt <= 8'd0;
             wave_wp  <= (wave_wp == 10'd639) ? 10'd0 : wave_wp + 10'd1;
             if (wave_fill != 10'd639)
                 wave_fill <= wave_fill + 10'd1;
         end else begin
             adec_cnt <= adec_cnt + 8'd1;
         end
     end
 end

wire [7:0]  pcm      = audio_data;                    
wire [7:0]  pcm_mag  = pcm[7] ? (~pcm + 8'd1) : pcm;  
wire [9:0] mag_raw = {1'b0, pcm_mag, 1'b0} + {2'b00, pcm_mag[7:1]};
wire [9:0]  mag_lim  = (mag_raw > WAVE_MAX) ? WAVE_MAX : mag_raw[9:0];
wire [9:0]  wave_y_wr = pcm[7] ? (WAVE_MID + mag_lim)     // 负半周 -> 向下
                                   : (WAVE_MID - mag_lim);    // 正半周 -> 向上

    reg [9:0] wave_mem [0:639];  

    always @(posedge clk) begin
        if (wave_wr)
            wave_mem[wave_wp] <= wave_y_wr;    
    end

wire [10:0] wave_sum  = {1'b0, wave_wp} + {1'b0, x_cnt};
wire [9:0]  wave_addr = (wave_sum >= 11'd640) ? (wave_sum - 11'd640) : wave_sum[9:0];
wire [9:0]  wave_y    = wave_mem[wave_addr];         

    reg  [9:0]  wave_y_d;
    always @(posedge clk or posedge rst) begin
        if (rst) wave_y_d <= 10'd0;
        else     wave_y_d <= wave_y;
    end
    
wire [9:0]  y_prev = (x_cnt == 10'd0) ? wave_y : wave_y_d;
wire [9:0]  y_lo = (wave_y < y_prev) ? wave_y : y_prev;
wire [9:0]  y_hi = (wave_y < y_prev) ? y_prev : wave_y;
wire in_wave_win  = de && wave_en &&
                        (y_cnt >= WAVE_TOP) && (y_cnt <= WAVE_BOT);
wire in_wave_line = in_wave_win && (wave_fill == 10'd639) &&
                        (y_cnt >= (y_lo - 10'd2)) && 
                        (y_cnt <= (y_lo + 10'd2)); 
                        
 // 叫号记录面板
 (* ASYNC_REG = "TRUE" *) reg [1:0] sw3_meta;
 always @(posedge clk or posedge rst) begin
     if (rst) sw3_meta <= 2'b00;
     else     sw3_meta <= {sw3_meta[0], sw3};
 end
 wire panel_en = sw3_meta[1];

 localparam [9:0] PANEL_L = 10'd400, PANEL_R = 10'd631;
 localparam [9:0] PANEL_T = 10'd120, PANEL_B = 10'd319;
 localparam [9:0] TX0     = 10'd408, TY0     = 10'd128; 

 wire in_panel = de && panel_en &&
                 (x_cnt >= PANEL_L) && (x_cnt <= PANEL_R) &&
                 (y_cnt >= PANEL_T) && (y_cnt <= PANEL_B);

 wire in_panel_frame = in_panel &&
                       ((x_cnt <= PANEL_L + 10'd1) || (x_cnt >= PANEL_R - 10'd1) ||
                        (y_cnt <= PANEL_T + 10'd1) || (y_cnt >= PANEL_B - 10'd1));

 wire in_panel_div = in_panel && (y_cnt == TY0 + 10'd18) &&
                     (x_cnt >= PANEL_L + 10'd6) && (x_cnt <= PANEL_R - 10'd6);

 wire in_cur_box = de && panel_en && blink_on &&
                   (x_cnt >= 10'd480) && (x_cnt <= 10'd527) &&
                   (y_cnt >= 10'd156) && (y_cnt <= 10'd179) &&
                   ((x_cnt <= 10'd481) || (x_cnt >= 10'd526) ||
                    (y_cnt <= 10'd157) || (y_cnt >= 10'd178));

 wire [9:0] px_rel = x_cnt - TX0;
 wire [9:0] py_rel = y_cnt - TY0;
 wire [3:0] p_cell_x = px_rel[7:4];
 wire [3:0] p_cell_y = py_rel[7:4];
 wire [3:0] p_col    = px_rel[3:0];     
 wire [3:0] p_row    = py_rel[3:0];    

 wire in_panel_text = in_panel &&
                      (x_cnt >= TX0) && (x_cnt < TX0 + 10'd224) &&   
                      (y_cnt >= TY0) && (y_cnt < TY0 + 10'd192);   

 wire [3:0] h0_ten = (hist0 / 10) % 10;
 wire [3:0] h0_one =  hist0 % 10;
 wire [3:0] h1_ten = (hist1 / 10) % 10;
 wire [3:0] h1_one =  hist1 % 10;
 wire [3:0] h2_ten = (hist2 / 10) % 10;
 wire [3:0] h2_one =  hist2 % 10;
 wire [3:0] pd_ten = (pending_num / 10) % 10;
 wire [3:0] pd_one =  pending_num % 10;

 reg [5:0] p_char_idx;
 reg       p_vld;
 reg       p_is_cur;

 always @(*) begin
     p_char_idx = 6'd0;
     p_vld      = 1'b0;
     p_is_cur   = 1'b0;
     case ({p_cell_y, p_cell_x})
         // ---------- row0：标题 "当前叫号" ----------
         {4'd0, 4'd0}: begin p_char_idx = 6'd34; p_vld = 1'b1; end
         {4'd0, 4'd1}: begin p_char_idx = 6'd35; p_vld = 1'b1; end
         {4'd0, 4'd2}: begin p_char_idx = 6'd36; p_vld = 1'b1; end
         {4'd0, 4'd3}: begin p_char_idx = 6'd37; p_vld = 1'b1; end
         // ---------- row2：当前号（闪烁）----------
         {4'd2, 4'd5}: if (blink_on) begin p_char_idx = 6'd21 + q_ten; p_vld = 1'b1; p_is_cur = 1'b1; end
         {4'd2, 4'd6}: if (blink_on) begin p_char_idx = 6'd21 + q_one; p_vld = 1'b1; p_is_cur = 1'b1; end
         // ---------- row4：历史 1（最近一次）----------
         {4'd4, 4'd2}: begin p_char_idx = 6'd22; p_vld = 1'b1; end          // '1'
         {4'd4, 4'd3}: begin p_char_idx = 6'd31; p_vld = 1'b1; end          // ':'
         {4'd4, 4'd5}: begin p_char_idx = 6'd21 + h0_ten; p_vld = 1'b1; end
         {4'd4, 4'd6}: begin p_char_idx = 6'd21 + h0_one; p_vld = 1'b1; end
         // ---------- row5：历史 2 ----------
         {4'd5, 4'd2}: begin p_char_idx = 6'd23; p_vld = 1'b1; end          // '2'
         {4'd5, 4'd3}: begin p_char_idx = 6'd31; p_vld = 1'b1; end
         {4'd5, 4'd5}: begin p_char_idx = 6'd21 + h1_ten; p_vld = 1'b1; end
         {4'd5, 4'd6}: begin p_char_idx = 6'd21 + h1_one; p_vld = 1'b1; end
         // ---------- row6：历史 3（最旧）----------
         {4'd6, 4'd2}: begin p_char_idx = 6'd24; p_vld = 1'b1; end          // '3'
         {4'd6, 4'd3}: begin p_char_idx = 6'd31; p_vld = 1'b1; end
         {4'd6, 4'd5}: begin p_char_idx = 6'd21 + h2_ten; p_vld = 1'b1; end
         {4'd6, 4'd6}: begin p_char_idx = 6'd21 + h2_one; p_vld = 1'b1; end
         // ---------- row8："请到诊室：X" ----------
         {4'd8, 4'd0}: begin p_char_idx = 6'd38; p_vld = 1'b1; end
         {4'd8, 4'd1}: begin p_char_idx = 6'd39; p_vld = 1'b1; end
         {4'd8, 4'd2}: begin p_char_idx = 6'd40; p_vld = 1'b1; end
         {4'd8, 4'd3}: begin p_char_idx = 6'd41; p_vld = 1'b1; end
         {4'd8, 4'd4}: begin p_char_idx = 6'd31; p_vld = 1'b1; end
         {4'd8, 4'd5}: begin p_char_idx = 6'd21 + room_num; p_vld = 1'b1; end
         // ---------- row10："叫号：XX"（待叫号人数）----------
         // ---------- row10："待叫号：XX位" ----------
         {4'd10, 4'd0}: begin p_char_idx = 6'd42; p_vld = 1'b1; end   // 待
         {4'd10, 4'd1}: begin p_char_idx = 6'd36; p_vld = 1'b1; end   // 叫
         {4'd10, 4'd2}: begin p_char_idx = 6'd37; p_vld = 1'b1; end   // 号
         {4'd10, 4'd3}: begin p_char_idx = 6'd31; p_vld = 1'b1; end   // ：
         {4'd10, 4'd5}: begin p_char_idx = 6'd21 + pd_ten; p_vld = 1'b1; end  // 十位
         {4'd10, 4'd6}: begin p_char_idx = 6'd21 + pd_one; p_vld = 1'b1; end  // 个位
         {4'd10, 4'd8}: begin p_char_idx = 6'd43; p_vld = 1'b1; end   
         default: ;
     endcase
 end

 wire [9:0]  p_rom_addr = {p_char_idx, p_row};
 wire [15:0] p_rom_row;
 wire p_dot = (p_vld && in_panel_text) ? p_rom_row[CELL - 1 - p_col] : 1'b0;

 char_rom #(
     .NCHAR (44),
     .CELL  (CELL),
     .ADDR_W(10)
 ) u_p_rom (
     .addr    (p_rom_addr),
     .row_data(p_rom_row)
 );      
 
    localparam [9:0] LOGO_LEFT = 10'd470;
    localparam [9:0] LOGO_TOP  = 10'd400;

    wire [9:0] logo_x = x_cnt - LOGO_LEFT;     
    wire [9:0] logo_y = y_cnt - LOGO_TOP;     

    wire logo_in_win = de &&
                       (x_cnt >= LOGO_LEFT) && (x_cnt < LOGO_LEFT + 10'd160) &&
                       (y_cnt >= LOGO_TOP ) && (y_cnt <  LOGO_TOP + 10'd31 );  

    wire [12:0] logo_addr = ({3'b000, logo_y} << 7)
                          + ({3'b000, logo_y} << 5)
                          + {3'b000, logo_x};
                          
    wire [23:0] logo_rgb_raw; 
    wire [23:0] logo_rgb;     

   
    assign logo_rgb = {logo_rgb_raw[7:0], logo_rgb_raw[15:8], logo_rgb_raw[23:16]};

    anlogic_logo_rom u_logo_rom (
        .clk  (clk),
        .addr (logo_addr),
        .data (logo_rgb_raw) 
    );

    reg logo_in_win_d1;
    always @(posedge clk or posedge rst) begin
        if (rst) logo_in_win_d1 <= 1'b0;
        else     logo_in_win_d1 <= logo_in_win; 
    end
               
 // 输出选择（组合逻辑，不引入额外流水延迟）
    always @(*) begin
    if (in_queue_area) begin
        //底部叫号
        if (q_dot) 
           rgb_out = 24'h000000;       
        else       
           rgb_out = QUEUE_BG_COLOR;    
    end else if (in_band) begin
        // 底部字幕
        if (in_text && dot)
            rgb_out = TEXT_COLOR;
        else
            rgb_out = BG_COLOR;
    end else if (in_brt_area) begin
        // 左上角亮度值
        if (brt_dot)
            rgb_out = BRT_COLOR;
        else
            rgb_out = rgb_in;
    end else if (in_ts_area) begin
       // 右上角时间戳
        if (ts_dot)
            rgb_out = TS_COLOR;
        else
            rgb_out = rgb_in;
    end else if (in_ts_area) begin
        // 右上角时间戳
         if (ts_dot)
             rgb_out = TS_COLOR;
         else
             rgb_out = rgb_in;
    end else if (in_panel) begin
        // 叫号记录面板 
        if (p_dot)
            rgb_out = p_is_cur ? 24'hFFFF00 : 24'h000000; 
        else if (in_panel_frame || in_cur_box)
            rgb_out = 24'h00C8D0;                        
        else if (in_panel_div)
            rgb_out = 24'h00A0A8;                        
        else
            rgb_out = 24'hC0E0F0;   
    end else if (logo_in_win_d1) begin
        // logo 叠加
        if (logo_rgb == 24'h000000) begin
            rgb_out = rgb_in; 
        end else begin
            rgb_out = {logo_rgb[7:0], logo_rgb[15:8], logo_rgb[23:16]}; 
        end                   
    end else if (in_wave_win) begin
        //音频波形窗口 
        if (in_wave_line)
            rgb_out = WAVE_COLOR; 
        else
            rgb_out = 24'hFFFFFF;
    end else begin
        rgb_out = rgb_in;
    end
end



endmodule
