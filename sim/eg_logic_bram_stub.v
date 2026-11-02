//============================================================================
// eg_logic_bram_stub.v —— 仅用于 iverilog 编译(elaboration)检查的仿真桩
// 用途：RAM_0.v 例化了安路原语 EG_LOGIC_BRAM（TD 专有，iverilog 无模型）。
//      本桩提供与 RAM_0.v 例化一致的端口，行为为最小可仿真模型（PDPW 语义：
//      端口 A 写、端口 B 读，读延迟 1 拍），仅供语法/elaboration 检查。
// 注意：不参与综合，不写入 rtl/ 或 al_ip/，不影响 TD 综合流程。
//============================================================================
`timescale 1ns / 1ps

module EG_LOGIC_BRAM #(
    parameter DATA_WIDTH_A = 32,
    parameter DATA_WIDTH_B = 32,
    parameter ADDR_WIDTH_A = 10,
    parameter ADDR_WIDTH_B = 10,
    parameter DATA_DEPTH_A = 1024,
    parameter DATA_DEPTH_B = 1024,
    parameter MODE         = "PDPW",
    parameter REGMODE_A    = "NOREG",
    parameter REGMODE_B    = "NOREG",
    parameter WRITEMODE_A  = "NORMAL",
    parameter WRITEMODE_B  = "NORMAL",
    parameter RESETMODE    = "SYNC",
    parameter IMPLEMENT    = "9K",
    parameter INIT_FILE    = "NONE",
    parameter FILL_ALL     = "NONE"
)(
    input  [DATA_WIDTH_A-1:0] dia,
    input  [DATA_WIDTH_B-1:0] dib,
    input  [ADDR_WIDTH_A-1:0] addra,
    input  [ADDR_WIDTH_B-1:0] addrb,
    input  cea,
    input  ceb,
    input  ocea,
    input  oceb,
    input  clka,
    input  clkb,
    input  wea,
    input  bea,
    input  web,
    input  [1:0] beb,
    input  rsta,
    input  rstb,
    output [DATA_WIDTH_A-1:0] doa,
    output [DATA_WIDTH_B-1:0] dob
);
    reg [DATA_WIDTH_A-1:0] mem [0:DATA_DEPTH_A-1];
    reg [DATA_WIDTH_B-1:0] dob_r;

    // 端口 A：写（wea=1）
    always @(posedge clka) begin
        if (cea && wea)
            mem[addra] <= dia;
    end

    // 端口 B：读，读延迟 1 拍（NOREG 模式下由外部地址→下一拍数据）
    always @(posedge clkb) begin
        if (ceb)
            dob_r <= mem[addrb];
    end

    assign dob = dob_r;
    assign doa = {DATA_WIDTH_A{1'b0}};

endmodule
