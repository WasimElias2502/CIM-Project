module xbar_slice import memarray_pkg::*; #(parameter int ROWS=32, COLS=32)(
  input  logic                      clk, rst_n,
  input  logic                      xbar_en,
  input  logic [COLS-1:0][2:0]      col_codes,
  input  logic [ROWS-1:0][2:0]      row_codes,
  input  axis_e                     op_axis,
  input  logic                      op_is_write,
  input  logic                      s1,           // capture into source registers
  input  logic                      s2,           // OR + commit
  output logic [ROWS-1:0][COLS-1:0] mem_dbg
  ); // read-out stub (open design point)


  logic [ROWS-1:0][COLS-1:0]                    srco;
  logic [ROWS-1:0][COLS-1:0]                    row_src_reg; // one N-bit register per row
  logic [COLS-1:0][ROWS-1:0]                    col_src_reg; // one N-bit register per column
  logic [ROWS-1:0]                              trig_row; 
  logic [COLS-1:0]                              trig_col;


  genvar r,c;
  generate for (r=0;r<ROWS;r++) for (c=0;c<COLS;c++) begin: g
    mem_cell u(.clk,.rst_n,
      .op_code  (op_axis==AXIS_COL ? col_codes[c] : row_codes[r]),
      .mask_code(op_axis==AXIS_COL ? row_codes[r] : col_codes[c]),
      .xbar_en,
      .op_is_write,
      .trigger  (op_axis==AXIS_COL ? trig_row[r] : trig_col[c]),
      .commit(s2),
      .src_out(srco[r][c]),
      .bit_out(mem_dbg[r][c]));
  end endgenerate

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin row_src_reg<='0; col_src_reg<='0; end
    else if (s1) for (int rr=0;rr<ROWS;rr++) for (int cc=0;cc<COLS;cc++) begin
      row_src_reg[rr][cc] <= srco[rr][cc];   // src_out feeds BOTH banks
      col_src_reg[cc][rr] <= srco[rr][cc];
    end


  always_comb begin
    for (int rr=0;rr<ROWS;rr++) trig_row[rr] = |row_src_reg[rr]; // active axis only is used
    for (int cc=0;cc<COLS;cc++) trig_col[cc] = |col_src_reg[cc];
  end
  
endmodule
