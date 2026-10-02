module memarray_top import memarray_pkg::*; #(
  parameter int ROWS=32, COLS=32, XBARS=8)(
  input  logic clk, rst_n,
  // AXI-Stream slaves (fire-and-forget from CtrlPIM; ready tied high)
  input     logic [3*COLS-1:0]                  s_col_tdata,  
  input     logic                               s_col_tvalid,  
  output    logic                               s_col_tready,
  input     logic [3*ROWS-1:0]                  s_row_tdata,  
  input     logic                               s_row_tvalid,  
  output    logic                               s_row_tready,
  input     logic [XBARS-1:0]                   s_xbar_tdata, 
  input     logic                               s_xbar_tvalid, 
  output    logic                               s_xbar_tready,
  output    logic                               err_sticky,   // protocol violations latch here
  output    logic [XBARS-1:0][ROWS-1:0][COLS-1:0] mem_dbg
  ); // read-out stub (open design point)
  
  
  logic                         s1, s2;
  logic busy;
  assign busy          = s1 | s2;
  assign s_col_tready  = ~busy;
  assign s_row_tready  = ~busy;
  assign s_xbar_tready = ~busy;
  
  logic [COLS-1:0][2:0]         colc; 
  logic [ROWS-1:0][2:0]         rowc; 
  logic [XBARS-1:0]             xb;
  
  
  
  wire fire = s_col_tvalid & s_row_tvalid & s_xbar_tvalid;
  
  
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin 
        s1<=0; 
        s2<=0; 
        colc<='0; 
        rowc<='0; 
        xb<='0; 
    end
    else begin
      s1 <= fire; s2 <= s1;
      if (fire) begin
        for (int c=0;c<COLS;c++) colc[c]    <= s_col_tdata[3*c +: 3];
        for (int r=0;r<ROWS;r++) rowc[r]    <= s_row_tdata[3*r +: 3];
        xb                                  <= s_xbar_tdata;
      end
    end
    
    
  axis_e op_axis; op_e op_type; logic op_is_write, viol;
  
  op_classifier #(
    .ROWS(ROWS),
    .COLS(COLS)) 
   u_cls(
        .col_codes(colc),
        .row_codes(rowc),
        .op_axis,
        .op_type,
        .op_is_write,
        .violation(viol)
   );
   
  wire beat_en = ~viol;
  
  
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) err_sticky<=0; 
    else if (s1 & viol) err_sticky<=1;
    
 
  genvar x;
  generate for (x=0;x<XBARS;x++) begin: gx
    xbar_slice #(
        .ROWS(ROWS),
        .COLS(COLS)) u_sl(
        .clk,
        .rst_n,
        .xbar_en(xb[x] & beat_en),
        .col_codes(colc),
        .row_codes(rowc),
        .op_axis,
        .op_is_write,
        .s1(s1 & beat_en),
        .s2(s2),
        .mem_dbg(mem_dbg[x]));
  end endgenerate
endmodule
