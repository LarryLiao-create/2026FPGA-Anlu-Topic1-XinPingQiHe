`timescale 1ns / 1ps

module bmp_read #(
    parameter [31:0] MAX_DIM = 32'd2048,
    parameter [31:0] MIN_W   = 32'd16
)(
    input                       clk,
    input                       rst,
    output                      ready,

    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [2:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [2:0]            scan_found_total,

    input                       load_start,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    output reg [3:0]            state_code,

    output reg [15:0]           img_width,
    output reg [15:0]           img_height,
    output reg                  img_cfg_valid,

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data
);

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;

reg [2:0]  state;
reg [9:0]  rd_cnt;

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [31:0] pixel_offset;
reg [31:0] width;
reg [31:0] height;
reg [15:0] bit_count;
reg [31:0] compression;

reg [31:0] scan_sector;
reg [31:0] load_sector_latched;
reg [31:0] bmp_len_cnt;

reg [31:0] row_byte_cnt;
reg [15:0] row_cnt;
reg [1:0]  bmp_byte_idx;
reg        load_pixels_done;

reg [31:0] file_len_eff_r;
reg [31:0] file_sectors_r;

//--------------------------------------------------------------------------
// BMP 头字段推导
//--------------------------------------------------------------------------
wire [31:0] abs_height = height[31] ? ((~height) + 32'd1) : height;
wire [31:0] row_bytes  = (width << 1) + width;                 // width * 3
wire [31:0] row_stride = (row_bytes + 32'd3) & 32'hFFFF_FFFC;  // 4 字节对齐
// MAX_DIM = 2048 时 row_stride <= 6144（13bit），height <= 2048（12bit），
// 用 13x12 乘法代替 32x32，避免在 100MHz SD 域引入大乘法器。
wire [12:0] row_stride13 = row_stride[12:0];
wire [11:0] height12     = abs_height[11:0];
wire [24:0] img_bytes_f  = row_stride13 * height12;
wire [31:0] img_bytes    = {7'd0, img_bytes_f};
wire [31:0] file_len_eff = (file_len != 32'd0) ? file_len
                                               : (pixel_offset + img_bytes);

// 只接受 24bit、无压缩、bottom-up、尺寸合理的 BMP
wire header_match = (header_0 == "B") && (header_1 == "M") &&
                    (width >= MIN_W) && (width <= MAX_DIM) &&
                    (!height[31]) &&
                    (abs_height >= 32'd1) && (abs_height <= MAX_DIM) &&
                    (bit_count == 16'd24) &&
                    (compression == 32'd0) &&
                    (pixel_offset >= 32'd54) &&
                    (pixel_offset < file_len_eff_r);

// 当前字节属于图像数据区
wire data_byte_valid = (state == ST_LOAD_DATA) &&
                       sd_sec_read_data_valid &&
                       (bmp_len_cnt >= pixel_offset) &&
                       !load_pixels_done;

// 一行最后一个字节（可能是像素字节，也可能是填充字节）
wire row_end = data_byte_valid && (row_byte_cnt == (row_stride - 32'd1));


assign ready = (state == ST_IDLE);

//--------------------------------------------------------------------------
// 头字段解析 + 有效文件长度计算
//--------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
        file_len_eff_r <= 32'd0;
        file_sectors_r <= 32'd1;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) &&
                 sd_sec_read_data_valid) begin
        case (rd_cnt)
            10'd0 : header_0 <= sd_sec_read_data;
            10'd1 : header_1 <= sd_sec_read_data;

            10'd2 : file_len[7:0]   <= sd_sec_read_data;
            10'd3 : file_len[15:8]  <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : file_len[31:24] <= sd_sec_read_data;

            10'd10: pixel_offset[7:0]   <= sd_sec_read_data;
            10'd11: pixel_offset[15:8]  <= sd_sec_read_data;
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;

            10'd18: width[7:0]   <= sd_sec_read_data;
            10'd19: width[15:8]  <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;

            10'd22: height[7:0]   <= sd_sec_read_data;
            10'd23: height[15:8]  <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;

            10'd28: bit_count[7:0]  <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;

            10'd30: compression[7:0]   <= sd_sec_read_data;
            10'd31: compression[15:8]  <= sd_sec_read_data;
            10'd32: compression[23:16] <= sd_sec_read_data;
            10'd33: compression[31:24] <= sd_sec_read_data;
            default: ;
        endcase

        // 头部字段到齐后，一次性算出有效文件长度和扇区数
        if (rd_cnt == 10'd33) begin
            file_len_eff_r <= file_len_eff;
            file_sectors_r <= (file_len_eff + 32'd511) >> 9;
        end
    end
end

//--------------------------------------------------------------------------
// 扫描/加载头部的字节计数
//--------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sd_sec_read_end)
            rd_cnt <= 10'd0;
    end else begin
        rd_cnt <= 10'd0;
    end
end

//--------------------------------------------------------------------------
// 像素数据字节计数（用于判断文件结束）
//--------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 32'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid)
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
    end else begin
        bmp_len_cnt <= 32'd0;
    end
end

//--------------------------------------------------------------------------
// 行内字节计数 + 填充跳过 + 3 字节拼像素
//   只有 row_byte_cnt < width*3 的字节参与拼像素；
//   row_byte_cnt 到 row_stride-1 后回绕，进入下一行。
//--------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        row_byte_cnt     <= 32'd0;
        row_cnt          <= 16'd0;
        bmp_byte_idx     <= 2'd0;
        load_pixels_done <= 1'b0;
        bmp_data_wr_en   <= 1'b0;
        bmp_data         <= 24'd0;
    end else if (state != ST_LOAD_DATA) begin
        row_byte_cnt     <= 32'd0;
        row_cnt          <= 16'd0;
        bmp_byte_idx     <= 2'd0;
        load_pixels_done <= 1'b0;
        bmp_data_wr_en   <= 1'b0;
    end else begin
        bmp_data_wr_en <= 1'b0;

        if (data_byte_valid) begin
            // 像素字节拼装：B -> G -> R
            if (row_byte_cnt < row_bytes) begin
                case (bmp_byte_idx)
                    2'd0: bmp_data[7:0]   <= sd_sec_read_data;
                    2'd1: bmp_data[15:8]  <= sd_sec_read_data;
                    2'd2: begin
                        bmp_data[23:16] <= sd_sec_read_data;
                        bmp_data_wr_en  <= 1'b1;
                    end
                    default: ;
                endcase
                bmp_byte_idx <= (bmp_byte_idx == 2'd2) ? 2'd0
                                                       : (bmp_byte_idx + 2'd1);
            end

            // 行字节计数（含填充字节）
            if (row_end) begin
                row_byte_cnt <= 32'd0;
                bmp_byte_idx <= 2'd0;
                if (row_cnt == (abs_height[15:0] - 16'd1))
                    load_pixels_done <= 1'b1;
                else
                    row_cnt <= row_cnt + 16'd1;
            end else begin
                row_byte_cnt <= row_byte_cnt + 32'd1;
            end
        end
    end
end

//--------------------------------------------------------------------------
// 主状态机
//--------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        state               <= ST_IDLE;
        state_code          <= 4'd0;
        sd_sec_read         <= 1'b0;
        sd_sec_read_addr    <= 32'd0;
        write_req           <= 1'b0;
        scan_done           <= 1'b0;
        scan_found_valid    <= 1'b0;
        scan_found_sector   <= 32'd0;
        scan_found_total    <= 3'd0;
        scan_sector         <= 32'd0;
        load_sector_latched <= 32'd0;
        img_width           <= 16'd0;
        img_height          <= 16'd0;
        img_cfg_valid       <= 1'b0;
    end else if (!sd_init_done) begin
        state               <= ST_IDLE;
        state_code          <= 4'd0;
        sd_sec_read         <= 1'b0;
        sd_sec_read_addr    <= 32'd0;
        write_req           <= 1'b0;
        scan_done           <= 1'b0;
        scan_found_valid    <= 1'b0;
        scan_found_sector   <= 32'd0;
        scan_found_total    <= 3'd0;
        scan_sector         <= 32'd0;
        load_sector_latched <= 32'd0;
        img_width           <= 16'd0;
        img_height          <= 16'd0;
        img_cfg_valid       <= 1'b0;
    end else begin
        scan_found_valid <= 1'b0;
        img_cfg_valid    <= 1'b0;

        case (state)
            ST_IDLE: begin
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    scan_done        <= 1'b0;
                    scan_found_total <= 3'd0;
                    scan_sector      <= scan_start_sector;
                    sd_sec_read_addr <= scan_start_sector;
                    state            <= ST_SCAN;
                end else if (load_start) begin
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    state               <= ST_LOAD_HDR;
                end
            end

            ST_SCAN: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;

                    if (header_match) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        scan_found_total  <= scan_found_total + 3'd1;

                        if ((scan_found_total + 3'd1 >= scan_target_count) ||
                            (scan_sector + file_sectors_r > scan_max_sector)) begin
                            scan_done        <= 1'b1;
                            state            <= ST_IDLE;
                            sd_sec_read_addr <= scan_sector + file_sectors_r;
                            scan_sector      <= scan_sector + file_sectors_r;
                        end else begin
                            sd_sec_read_addr <= scan_sector + file_sectors_r;
                            scan_sector      <= scan_sector + file_sectors_r;
                        end
                    end else begin
                        if (scan_sector >= scan_max_sector) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= scan_sector + 32'd1;
                            scan_sector      <= scan_sector + 32'd1;
                        end
                    end
                end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_match) begin
                        img_width     <= width[15:0];
                        img_height    <= abs_height[15:0];
                        img_cfg_valid <= 1'b1;
                        write_req     <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        state         <= ST_LOAD_WAIT;
                    end else begin
                        state <= ST_IDLE;
                    end
                end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_req_ack) begin
                    write_req <= 1'b0;
                    state     <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                state_code  <= 4'd4;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (load_pixels_done || (bmp_len_cnt >= file_len_eff_r))
                        state <= ST_IDLE;
                    else
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                end
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule