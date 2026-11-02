module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       key_auto,
    input                       xfd_busy,       // 转场进行中：禁止启动新写图任务
    output [3:0]                state_code,
    input  [15:0]               bmp_width,      // 保留端口，Phase 1 不再使用
    input  [15:0]               bmp_height,     // 保留端口，Phase 1 不再使用
    output reg                  display_valid,
    output reg                  load_stuck,

    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    input                       write_full,     
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

wire key_next_press;
wire key_auto_press;

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;

// bmp_read 原始像素流
wire             bmp_pix_valid;
wire [23:0]      bmp_pix_data;

// bmp_scale 缩放后像素流
wire             scale_out_valid;
wire [23:0]      scale_out_pixel;
wire             scale_busy;
wire             scale_done;

// bmp_read 导出的源图尺寸
wire [15:0]      img_width;
wire [15:0]      img_height;
wire             img_cfg_valid;

wire             sd_init_done;
wire             bmp_ready;
wire             scan_done_raw; 
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [2:0]       scan_found_total;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              first_image_committed;
reg              auto_play_en;
reg [31:0]       auto_cnt;
reg [2:0]        img_found_count;
reg [1:0]        img_idx;              // 当前真正显示中的图片编号
reg [1:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        try_idx;              // 上一次"尝试"的编号（无论成功失败）：
                                       // 用它算下一张，避免某张图加载失败后
                                       // 每次按键都重试同一张 -> 死循环
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg              next_req_pending;
reg              load_busy;

localparam [29:0] LOAD_TIMEOUT = 30'd1_000_000_000;

reg [29:0] load_timeout_cnt;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            load_timeout_cnt <= 30'd0;
            load_stuck       <= 1'b0;
        end else if (!load_busy) begin
            load_timeout_cnt <= 30'd0;
            load_stuck       <= 1'b0;
        end else if (load_timeout_cnt >= LOAD_TIMEOUT) begin
            load_stuck       <= 1'b1;      // 粘滞，直到整链复位把它清掉
        end else begin
            load_timeout_cnt <= load_timeout_cnt + 30'd1;
        end
    end


reg scan_done_r;
always @(posedge clk or posedge rst) begin
    if (rst)                scan_done_r <= 1'b0;
    else if (!sd_init_done) scan_done_r <= 1'b0;
    else if (scan_done_raw) scan_done_r <= 1'b1;
end
wire scan_done = scan_done_raw | scan_done_r; 

// 切图死锁超时保护：28 位 ≈ 2.68s @100MHz

localparam [27:0] LOAD_ABORT_MAX = 28'd268_000_000; 

reg  [27:0] abort_cnt;
wire        load_abort = load_busy && (abort_cnt >= LOAD_ABORT_MAX);

always @(posedge clk or posedge rst) begin
        if (rst)
            abort_cnt <= 28'd0;
        else if (!load_busy)
            abort_cnt <= 28'd0;                 
        else if (abort_cnt >= LOAD_ABORT_MAX)
            abort_cnt <= abort_cnt;           
        else
            abort_cnt <= abort_cnt + 28'd1;
end

reg [3:0] abort_rst_cnt;
always @(posedge clk or posedge rst) begin
        if (rst)
            abort_rst_cnt <= 4'd0;
        else if (load_abort)
            abort_rst_cnt <= 4'd8;
        else if (abort_rst_cnt != 4'd0)
            abort_rst_cnt <= abort_rst_cnt - 4'd1;
end
wire load_abort_rst = (abort_rst_cnt != 4'd0);
    
//转场互锁
reg              xfd_hold;
reg              xfd_seen;
reg              source_done_seen;
reg              write_done_seen;  
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;
wire auto_tick;
wire [1:0] next_from_current;


localparam [2:0] THR_MASK = 3'd3;

reg  [2:0] wr_thr_cnt;
    always @(posedge clk or posedge rst) begin
        if (rst) wr_thr_cnt <= 3'd0;
        else     wr_thr_cnt <= wr_thr_cnt + 3'd1;
    end

wire wr_thr_stall = ((wr_thr_cnt & THR_MASK) != 3'd0);
wire wr_stall     = write_full | wr_thr_stall;

localparam [18:0] FRAME_PIX = 19'd307200;
reg [18:0] load_pix_cnt;

always @(posedge clk or posedge rst) begin
        if (rst)                   load_pix_cnt <= 19'd0;
        else if (load_start_pulse) load_pix_cnt <= 19'd0;
        else if (write_en)         load_pix_cnt <= load_pix_cnt + 19'd1;
end

wire frame_len_ok = (load_pix_cnt == FRAME_PIX);

assign write_en   = scale_out_valid & ~wr_stall;
assign write_data = {scale_out_pixel[23:0], 8'b0};

assign auto_tick  = (auto_cnt == (CLK_FREQ_HZ - 1));
assign next_from_current = next_index_limited(try_idx, img_found_count);
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];

localparam [27:0] XFD_HOLD_MAX = 28'd10_000_000;

reg [27:0] xfd_hold_cnt;
always @(posedge clk or posedge rst) begin
        if (rst)
            xfd_hold_cnt <= 28'd0;
        else if (!xfd_hold || xfd_busy)
            xfd_hold_cnt <= 28'd0;                  
        else if (xfd_hold_cnt != XFD_HOLD_MAX)
            xfd_hold_cnt <= xfd_hold_cnt + 28'd1;
end
wire xfd_hold_timeout = (xfd_hold_cnt >= XFD_HOLD_MAX);

// 上电按键封锁
reg [24:0] boot_lock_cnt;
always @(posedge clk or posedge rst) begin
    if (rst)
        boot_lock_cnt <= 25'd0;
    else if (boot_lock_cnt != 25'd30_000_000)     
            boot_lock_cnt <= boot_lock_cnt + 25'd1;
end
wire keys_locked = (boot_lock_cnt != 25'd30_000_000);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press)
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(key_auto_press)
);

function [1:0] next_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: next_index_limited = 2'd0;
            3'd1: next_index_limited = 2'd0;
            3'd2: next_index_limited = (cur == 2'd1) ? 2'd0 : (cur + 2'd1);
            3'd3: next_index_limited = (cur == 2'd2) ? 2'd0 : (cur + 2'd1);
            default: next_index_limited = (cur == 2'd3) ? 2'd0 : (cur + 2'd1);
        endcase
    end
endfunction

function [31:0] sector_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: sector_lut = img_sector0;
            2'd1: sector_lut = img_sector1;
            2'd2: sector_lut = img_sector2;
            2'd3: sector_lut = img_sector3;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;             
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
        auto_play_en          <= 1'b0;
        auto_cnt              <= 32'd0;
        img_found_count       <= 3'd0;
        img_idx               <= 2'd0;
        load_idx              <= 2'd0;
        try_idx               <= 2'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        next_req_pending      <= 1'b0;
        load_busy             <= 1'b0;
        source_done_seen      <= 1'b0;
        write_done_seen       <= 1'b0;
        display_valid         <= 1'b0;
        xfd_hold              <= 1'b0;
        xfd_seen              <= 1'b0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;

        // ---- 转场互锁清除 ----
        if (xfd_busy) begin
            xfd_seen <= 1'b1;
        end else if (xfd_seen) begin
            xfd_hold <= 1'b0;
            xfd_seen <= 1'b0;
        end else if (xfd_hold_timeout) begin   
            xfd_hold <= 1'b0;
            xfd_seen <= 1'b0;
        end



        if (!sd_init_done) begin
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 3'd0;
            img_idx               <= 2'd0;
            load_idx              <= 2'd0;
            try_idx               <= 2'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            next_req_pending      <= 1'b0;
            load_busy             <= 1'b0;
            source_done_seen      <= 1'b0;
            write_done_seen       <= 1'b0;
            display_valid         <= 1'b0;
            xfd_hold              <= 1'b0;
            xfd_seen              <= 1'b0;
        end else begin
            // 扫描阶段缓存前 4 张图的起始 sector
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    default: ;
                endcase

                if (img_found_count < 3'd4)
                    img_found_count <= img_found_count + 3'd1;
            end

            // 缩放模块已输出完 640x480；真正的提交仍要等整帧写进 SDRAM
            if (load_busy && scale_done)
                source_done_seen <= 1'b1;

            if (load_busy && write_finish_pulse)
                write_done_seen <= 1'b1;

             if (load_busy && 
                (source_done_seen || scale_done) && 
                (write_done_seen  || write_finish_pulse) &&
                (frame_len_ok     || write_done_seen)) begin
                
                
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
                disp_buf_idx          <= pending_buf_idx;
                img_idx               <= load_idx;
                display_valid         <= 1'b1;
                first_image_committed <= 1'b1;
                xfd_hold              <= (pending_buf_idx != disp_buf_idx);
                xfd_seen              <= 1'b0;
            end
            

            if (load_abort) begin
                // 超时兜底：① 无条件解开链路，保证按键/自动播放立刻可用；
                //           ② 只有整帧完整才切图，残帧一律不显示（见下）。
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
                next_req_pending      <= 1'b0;

                // 只有整帧 307200 像素完整落地才切图：半截图一旦被推上屏就是花屏，
                // 切到另一块 buffer 才恢复；这里宁可保留旧图，也不显示残帧。
                if (frame_len_ok) begin
                    disp_buf_idx          <= pending_buf_idx;
                    img_idx               <= load_idx;
                    display_valid         <= 1'b1;
                    first_image_committed <= 1'b1;
                    xfd_hold              <= (pending_buf_idx != disp_buf_idx);
                    xfd_seen              <= 1'b0;
                end
            end

            // 上电后自动发起一次“扫描前 4 张 BMP”
            if (!scan_kicked && bmp_ready) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                auto_play_en          <= 1'b0;
                auto_cnt              <= 32'd0;
                img_found_count       <= 3'd0;
                img_idx               <= 2'd0;
                load_idx              <= 2'd0;
                try_idx               <= 2'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx         <= 2'd0;
                disp_buf_idx          <= 2'd0;
                next_req_pending      <= 1'b0;
                display_valid         <= 1'b0;
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0; 
            end else begin
                if (key_next_press && !keys_locked && first_image_committed &&
                    scan_done && (img_found_count > 3'd0))
                    next_req_pending <= 1'b1;

                // 自动播放开/关
                if (key_auto_press && !keys_locked && scan_done && (img_found_count > 3'd1)) begin
                    auto_play_en <= ~auto_play_en;
                    auto_cnt     <= 32'd0;
                end

                // 自动播放 1s 计数
                if (scan_done && auto_play_en && display_valid && !load_busy &&
                    !xfd_hold && first_image_committed && (img_found_count > 3'd1)) begin
                    if (auto_tick)
                        auto_cnt <= 32'd0;
                    else
                        auto_cnt <= auto_cnt + 32'd1;
                end else begin
                    auto_cnt <= 32'd0;
                end

                // 首图自动加载到 buffer0
                if (scan_done && !first_image_committed && bmp_ready && !load_busy &&
                    !xfd_hold && (img_found_count != 3'd0)) begin
                    load_idx         <= 2'd0;
                    try_idx          <= 2'd0;
                    load_sector      <= img_sector0;
                    pending_buf_idx  <= 2'd0;
                    write_buf_idx    <= 2'd0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0; 
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 手动下一张
                else if (scan_done && bmp_ready && display_valid && !load_busy &&
                         !xfd_hold && next_req_pending && (img_found_count != 3'd0)) begin
                    load_idx         <= next_from_current;
                    try_idx          <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0; 
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 自动播放下一张
                else if (scan_done && bmp_ready && display_valid && !load_busy &&
                         !xfd_hold && auto_play_en && auto_tick && (img_found_count > 3'd1)) begin
                    load_idx         <= next_from_current;
                    try_idx          <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0; 
                    auto_cnt         <= 32'd0;
                end
            end
        end
    end
end

//--------------------------------------------------------------------------
// BMP 读取：解析头 + 输出原始 24bit 像素流
//--------------------------------------------------------------------------
bmp_read bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst | load_abort_rst),  
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done_raw),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code),

    .img_width              (img_width),
    .img_height             (img_height),
    .img_cfg_valid          (img_cfg_valid),

    .write_req              (write_req),
    .write_req_ack          (write_req_ack),

    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),

    .bmp_data_wr_en         (bmp_pix_valid),
    .bmp_data               (bmp_pix_data)
);

//--------------------------------------------------------------------------
// 水平缩放 + 保比例黑边
//--------------------------------------------------------------------------
bmp_scale #(
) u_bmp_scale (
    .clk        (clk),
    .rst        (rst | load_abort_rst),
    .start      (img_cfg_valid),
    .src_width  (img_width),
    .src_height (img_height),
    .in_valid   (bmp_pix_valid),
    .in_pixel   (bmp_pix_data),
    .out_ready (~wr_stall),      // 新增：FIFO 满时暂停
    .out_valid  (scale_out_valid),
    .out_pixel  (scale_out_pixel),
    .busy       (scale_busy),
    .done       (scale_done)
);

//--------------------------------------------------------------------------
// SD 卡底层
//--------------------------------------------------------------------------
sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

endmodule


module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule