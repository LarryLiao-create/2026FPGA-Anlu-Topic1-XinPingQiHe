//============================================================================
// vendor_prim_stub.v —— 安路厂商原语/加密 IP 的仿真桩（仅供 iverilog 编译检查）
// 用途：top 例化的 EG_PHY_*/EG_LOGIC_*/sdr_as_ram/hdmi 加密核在 iverilog 下无模型。
//      本文件提供空实现，使整设计能通过 elaboration（端口连接检查）。
// 注意：不参与综合，不影响 TD 流程；输出端口全部拉 0。
//============================================================================
`timescale 1ns / 1ps

// ---- 时钟 BUFG ----
module EG_LOGIC_BUFG (input wire i, output wire o);
    assign o = i;
endmodule

// ---- ODDR ----
module EG_LOGIC_ODDR (input wire clk, input wire rst,
                      input wire d1, input wire d0, output wire q);
    assign q = d0;
endmodule

// ---- PLL ----
module EG_PHY_PLL #(
    parameter DPHASE_SOURCE = "DISABLE",
    parameter DYNCFG        = "DISABLE",
    parameter FIN           = "50.000000",
    parameter FEEDBK_MODE   = "NORMAL",
    parameter FEEDBK_PATH   = "CLKC0_EXT",
    parameter STDBY_ENABLE  = "DISABLE",
    parameter PLLRST_ENA    = "ENABLE",
    parameter SYNC_ENABLE   = "DISABLE",
    parameter GMC_GAIN      = 4,
    parameter ICP_CURRENT   = 29,
    parameter KVCO          = 4,
    parameter LPF_CAPACITOR = 1,
    parameter LPF_RESISTOR  = 2,
    parameter REFCLK_DIV    = 1,
    parameter FBCLK_DIV     = 2,
    parameter CLKC0_ENABLE  = "ENABLE", parameter CLKC0_DIV = 10, parameter CLKC0_CPHASE = 9, parameter CLKC0_FPHASE = 0,
    parameter CLKC1_ENABLE  = "ENABLE", parameter CLKC1_DIV = 8,  parameter CLKC1_CPHASE = 7, parameter CLKC1_FPHASE = 0,
    parameter CLKC2_ENABLE  = "ENABLE", parameter CLKC2_DIV = 8,  parameter CLKC2_CPHASE = 3, parameter CLKC2_FPHASE = 0
)(
    input  wire        refclk,
    input  wire        reset,
    input  wire        stdby,
    output wire        extlock,
    input  wire        load_reg,
    input  wire        psclk,
    input  wire        psdown,
    input  wire        psstep,
    input  wire [2:0]  psclksel,
    output wire        psdone,
    input  wire        dclk,
    input  wire        dcs,
    input  wire        dwe,
    input  wire [7:0]  di,
    input  wire [5:0]  daddr,
    output wire [7:0]  do,
    input  wire        fbclk,
    output wire [4:0]  clkc
);
    assign extlock = 1'b1;     // 仿真：锁定
    assign psdone  = 1'b0;
    assign do      = 8'b0;
    assign clkc    = 5'b0;     // 仿真时钟为 0，仅用于编译检查
endmodule

// ---- SDRAM 控制器内核（加密 sdr_as_ram）----
module sdr_as_ram #(
    parameter self_refresh_open = 1'b1
)(
    input  wire        Sdr_clk,
    input  wire        Sdr_clk_sft,
    input  wire        Rst,
    output wire        Sdr_init_done,
    output wire        Sdr_init_ref_vld,
    output wire        Sdr_busy,
    input  wire        App_ref_req,
    input  wire        App_wr_en,
    input  wire [20:0] App_wr_addr,
    input  wire [3:0]  App_wr_dm,
    input  wire [31:0] App_wr_din,
    input  wire        App_rd_en,
    input  wire [20:0] App_rd_addr,
    output wire        Sdr_rd_en,
    output wire [31:0] Sdr_rd_dout,
    output wire        SDRAM_CLK,
    output wire        SDR_RAS,
    output wire        SDR_CAS,
    output wire        SDR_WE,
    output wire [1:0]  SDR_BA,
    output wire [10:0] SDR_ADDR,
    output wire [3:0]  SDR_DM,
    inout  wire [31:0] SDR_DQ
);
    assign Sdr_init_done    = 1'b1;   // 仿真：直接认为初始化完成
    assign Sdr_init_ref_vld = 1'b0;
    assign Sdr_busy         = 1'b0;
    assign Sdr_rd_en        = 1'b0;
    assign Sdr_rd_dout      = 32'b0;
    assign SDRAM_CLK        = Sdr_clk;
    assign SDR_RAS = 1'b1; assign SDR_CAS = 1'b1; assign SDR_WE = 1'b1;
    assign SDR_BA  = 2'b0;
    assign SDR_ADDR = 11'b0;
    assign SDR_DM  = 4'b0;
    assign SDR_DQ  = 32'bz;
endmodule

// ---- 片内 SDRAM 存储阵列原语 ----
module EG_PHY_SDRAM_2M_32 (
    input  wire        clk,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [10:0] addr,
    input  wire [1:0]  ba,
    inout  wire [31:0] dq,
    input  wire        cs_n,
    input  wire        dm0,
    input  wire        dm1,
    input  wire        dm2,
    input  wire        dm3,
    input  wire        cke
);
    assign dq = 32'bz;
endmodule

// ---- HDMI 1.4b 发射核（加密 wrapper）----
module hdmi_1_4b_transmitter_core_wrapper #(
    parameter DEVICE            = "EG",
    parameter HTOTAL            = 800,
    parameter HSA               = 96,
    parameter HFP               = 16,
    parameter HBP               = 48,
    parameter HACTIVE           = 640,
    parameter VTOTAL            = 525,
    parameter VSA               = 2,
    parameter VFP               = 10,
    parameter VBP               = 33,
    parameter VACTIVE           = 480,
    parameter VIDEO_VIC         = 1,
    parameter VIDEO_TPG         = "Disable",
    parameter VIDEO_FORMAT      = "RGB",
    parameter AUDIO_SAMPLE_RATE = "48K",
    parameter IIC_SCL_DIV       = 250
)(
    input  wire        I_pixel_clk,
    input  wire        I_rst,
    input  wire        I_edid_read_trig,
    output wire        O_edid_read_valid,
    output wire [7:0]  O_edid_read_data,

    input  wire        I_axis_s_user,
    input  wire        I_axis_s_valid,
    input  wire        I_axis_s_last,
    input  wire [23:0] I_axis_s_data,
    output wire        O_axis_s_ready,

    input  wire        I_audio_valid,
    input  wire [23:0] I_audio_left_data,
    input  wire [23:0] I_audio_right_data,
    input  wire        I_acr_valid,
    input  wire [19:0] I_acr_cts,
    input  wire [19:0] I_acr_n,

    output wire        O_video_locked,
    output wire        O_ddc_scl,
    inout  wire        IO_ddc_sda,

    output wire [9:0]  O_ch0_tmds_data,
    output wire [9:0]  O_ch1_tmds_data,
    output wire [9:0]  O_ch2_tmds_data,
    output wire [9:0]  O_clk_tmds_data
);
    assign O_edid_read_valid = 1'b0;
    assign O_edid_read_data  = 8'b0;
    assign O_axis_s_ready    = 1'b1;
    assign O_video_locked    = 1'b1;
    assign O_ddc_scl         = 1'b1;
    assign IO_ddc_sda        = 1'bz;
    assign O_ch0_tmds_data   = 10'b0;
    assign O_ch1_tmds_data   = 10'b0;
    assign O_ch2_tmds_data   = 10'b0;
    assign O_clk_tmds_data   = 10'b0;
endmodule
