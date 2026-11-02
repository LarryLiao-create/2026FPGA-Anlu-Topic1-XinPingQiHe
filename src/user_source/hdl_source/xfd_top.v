`timescale 1ns / 1ps

module xfd_cdc2 #(
    parameter W = 1
)(
    input  wire             clk,
    input  wire             rst,
    input  wire [W-1:0]     d,
    output wire [W-1:0]     q
);
    (* ASYNC_REG = "TRUE" *) reg [W-1:0] q0;
    (* ASYNC_REG = "TRUE" *) reg [W-1:0] q;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            q0 <= {W{1'b0}};
            q  <= {W{1'b0}};
        end else begin
            q0 <= d;
            q  <= q0;
        end
    end
endmodule

module xfd_top #(
    parameter ALPHA_STEP = 4,           
    parameter ADDR_BITS  = 21,          
    parameter BUF0_ADDR  = 21'd0,      
    parameter BUF1_ADDR  = 21'd307200,  
    parameter BUF2_ADDR  = 21'd614400   
)(
   
    input  wire        video_clk,       
    input  wire        ext_mem_clk,     
    input  wire        sd_card_clk,      
    input  wire        rst,            

   
    input  wire        hs_0,            
    input  wire        vs_0,             
    input  wire        de_0,            

   
    input  wire [1:0]  disp_buf_idx,    

   
    input  wire        fifo_App_rd_en,   
    input  wire [ADDR_BITS-1:0] fifo_App_rd_addr,  

  
    input  wire        Sdr_rd_en,       
    input  wire [31:0] Sdr_rd_dout,     

   
    input  wire        hs_fifo,         
    input  wire        vs_fifo,         
    input  wire        de_fifo,          
    input  wire [23:0] rgb_fifo,         

   
    output wire        App_rd_en,  
    output wire [ADDR_BITS-1:0] App_rd_addr,
    output wire        Sdr_rd_en_gated,
    output wire        xfd_en,     
    output wire        xfd_busy_sd,    
    output wire        hs,              
    output wire        vs,             
    output wire        de,              
    output wire [23:0] vout_data         
);

    wire        xfd_en_v;       
    wire        xfd_busy_v;     
    (* keep = "true", chipwatcher = "true" *)wire [8:0]  xfd_alpha;     
    wire [1:0]  xfd_old_idx;    
    wire [1:0]  xfd_new_idx;   
    wire        xfd_vs_tgl;    
    wire        xfd_line_tgl;   
    wire        xfd_en_mem;   
    wire [1:0]  old_idx_mem;    
    wire [1:0]  new_idx_mem;    
    wire        vs_tgl_m;       
    wire        line_tgl_m; 
    wire [ADDR_BITS-1:0] old_base;
    wire [ADDR_BITS-1:0] new_base;
    wire        xfd_fetch_rd_en;    
    wire [ADDR_BITS-1:0] xfd_fetch_rd_addr; 
    wire        wr_en_old;          
    wire        wr_en_new;         
    wire        wr_page;            
    wire [9:0]  wr_addr;             
    wire [31:0] wr_data;           
    wire        rd_page;            
    wire [9:0]  rd_addr;            
    wire [31:0] old_p0_dob;         
    wire [31:0] old_p1_dob;         
    wire [31:0] new_p0_dob;       
    wire [31:0] new_p1_dob;          
    wire [31:0] old_dob;            
    wire [31:0] new_dob;            
    wire        xfd_hs;           
    wire        xfd_vs;            
    wire        xfd_de;             
    wire [23:0] xfd_rgb;            


    // xfd_en: video 域 → mem 域
    xfd_cdc2 #(.W(1)) u_sync_xfd_en (
        .clk(ext_mem_clk),
        .rst(rst),
        .d(xfd_en_v),
        .q(xfd_en_mem)
    );

    // xfd_busy: video 域 → sd 域
    xfd_cdc2 #(.W(1)) u_sync_xfd_busy (
        .clk(sd_card_clk),
        .rst(rst),
        .d(xfd_busy_v),
        .q(xfd_busy_sd)
    );

    // old_idx: video 域 → mem 域
    xfd_cdc2 #(.W(2)) u_sync_old_idx (
        .clk(ext_mem_clk),
        .rst(rst),
        .d(xfd_old_idx),
        .q(old_idx_mem)
    );

    // new_idx: video 域 → mem 域
    xfd_cdc2 #(.W(2)) u_sync_new_idx (
        .clk(ext_mem_clk),
        .rst(rst),
        .d(xfd_new_idx),
        .q(new_idx_mem)
    );

    // vs_tgl: video 域 → mem 域
    xfd_cdc2 #(.W(1)) u_sync_vs_tgl (
        .clk(ext_mem_clk),
        .rst(rst),
        .d(xfd_vs_tgl),
        .q(vs_tgl_m)
    );

    // line_tgl: video 域 → mem 域
    xfd_cdc2 #(.W(1)) u_sync_line_tgl (
        .clk(ext_mem_clk),
        .rst(rst),
        .d(xfd_line_tgl),
        .q(line_tgl_m)
    );

    assign old_base = (old_idx_mem == 2'd0) ? BUF0_ADDR :
                      (old_idx_mem == 2'd1) ? BUF1_ADDR : BUF2_ADDR;

    assign new_base = (new_idx_mem == 2'd0) ? BUF0_ADDR :
                      (new_idx_mem == 2'd1) ? BUF1_ADDR : BUF2_ADDR;
    xfd_ctrl #(
        .ALPHA_STEP(ALPHA_STEP)
    ) u_xfd_ctrl (
        .video_clk    (video_clk),
        .rst          (rst),
        .disp_buf_idx (disp_buf_idx), 
        .vs_in        (vs_0),
        .de_in        (de_0),
        .xfd_en       (xfd_en_v),
        .xfd_busy     (xfd_busy_v),
        .alpha        (xfd_alpha),
        .old_idx      (xfd_old_idx),
        .new_idx      (xfd_new_idx),
        .vs_tgl       (xfd_vs_tgl),
        .line_tgl     (xfd_line_tgl)
    );

    assign xfd_en = xfd_en_v;
    xfd_line_fetch #(
        .ADDR_BITS  (ADDR_BITS),
        .LINE_LEN   (640),
        .ROW_MAX    (479),
        .BURST_SIZE (256)
    ) u_xfd_line_fetch (
        .rst          (rst),
        .mem_clk      (ext_mem_clk),
        .xfd_en       (xfd_en_mem),       
        .vs_tgl       (vs_tgl_m),          
        .line_tgl     (line_tgl_m),      
        .old_base     (old_base),
        .new_base     (new_base),
        .App_rd_en    (xfd_fetch_rd_en),
        .App_rd_addr  (xfd_fetch_rd_addr),
        .Sdr_rd_en    (Sdr_rd_en),
        .Sdr_rd_dout  (Sdr_rd_dout),
        .wr_en_old    (wr_en_old),
        .wr_en_new    (wr_en_new),
        .wr_page      (wr_page),
        .wr_addr      (wr_addr),
        .wr_data      (wr_data),
        .fetch_row    (),                
        .busy         ()                
    );


    RAM_0 u_ram_old_p0 (
        .clka  (ext_mem_clk),
        .cea   (wr_en_old & ~wr_page),  
        .addra (wr_addr),
        .dia   (wr_data),
        .clkb  (video_clk),
        .addrb (rd_addr),
        .dob   (old_p0_dob)
    );

    RAM_0 u_ram_old_p1 (
        .clka  (ext_mem_clk),
        .cea   (wr_en_old & wr_page),  
        .addra (wr_addr),
        .dia   (wr_data),
        .clkb  (video_clk),
        .addrb (rd_addr),
        .dob   (old_p1_dob)
    );

    RAM_0 u_ram_new_p0 (
        .clka  (ext_mem_clk),
        .cea   (wr_en_new & ~wr_page),  
        .addra (wr_addr),
        .dia   (wr_data),
        .clkb  (video_clk),
        .addrb (rd_addr),
        .dob   (new_p0_dob)
    );

    RAM_0 u_ram_new_p1 (
        .clka  (ext_mem_clk),
        .cea   (wr_en_new & wr_page),   
        .addra (wr_addr),
        .dia   (wr_data),
        .clkb  (video_clk),
        .addrb (rd_addr),
        .dob   (new_p1_dob)
    );
    assign old_dob = rd_page ? old_p1_dob : old_p0_dob;
    assign new_dob = rd_page ? new_p1_dob : new_p0_dob;

    xfd_disp_pipe #(
        .LINE_LEN (640),
        .LAT      (20)
    ) u_xfd_disp_pipe (
        .video_clk (video_clk),
        .rst       (rst),
        .xfd_en    (xfd_en_v),
        .alpha     (xfd_alpha),
        .hs_in     (hs_0),
        .vs_in     (vs_0),
        .de_in     (de_0),
        .rd_page   (rd_page),
        .rd_addr   (rd_addr),
        .old_dob   (old_dob),
        .new_dob   (new_dob),
        .hs_out    (xfd_hs),
        .vs_out    (xfd_vs),
        .de_out    (xfd_de),
        .rgb_out   (xfd_rgb),
        .disp_row  ()                  
    );

    assign App_rd_en   = xfd_en_mem ? xfd_fetch_rd_en   : fifo_App_rd_en;
    assign App_rd_addr = xfd_en_mem ? xfd_fetch_rd_addr : fifo_App_rd_addr;
    assign Sdr_rd_en_gated = Sdr_rd_en & ~xfd_en_mem;
    assign hs        = xfd_en_v ? xfd_hs  : hs_fifo;
    assign vs        = xfd_en_v ? xfd_vs  : vs_fifo;
    assign de        = xfd_en_v ? xfd_de  : de_fifo;
    assign vout_data = xfd_en_v ? xfd_rgb : rgb_fifo;

endmodule
