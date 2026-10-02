module op_classifier import memarray_pkg::*; #(parameter int ROWS=32, COLS=32)
(
  input  logic [COLS-1:0][2:0]              col_codes,
  input  logic [ROWS-1:0][2:0]              row_codes,
  output axis_e                             op_axis,
  output op_e                               op_type,
  output logic                              op_is_write,
  output logic                              violation
  );
  
  
  function automatic logic has_op(input logic [2:0] c);
    return (c==C_VG)||(c==C_VW1)||(c==C_VW0);
  endfunction
  
  
  logic col_op, row_op;
  int unsigned n_src, n_dst, n_set, n_rst;
  logic [2:0] c;
  
  
  always_comb begin
    col_op=0; row_op=0;
    for (int i=0;i<COLS;i++) col_op |= has_op(col_codes[i]);
    for (int i=0;i<ROWS;i++) row_op |= has_op(row_codes[i]);
    op_axis = row_op & ~col_op ? AXIS_ROW : AXIS_COL; // default column axis
    n_src=0;n_dst=0;n_set=0;n_rst=0;
    if (op_axis==AXIS_COL) begin
      for (int i=0;i<COLS;i++) begin c=col_codes[i];
        n_src+=(c==C_VG); n_dst+=(c==C_GND); n_set+=(c==C_VW1); n_rst+=(c==C_VW0); end
    end else begin
      for (int i=0;i<ROWS;i++) begin c=row_codes[i];
        n_src+=(c==C_VG); n_dst+=(c==C_GND); n_set+=(c==C_VW1); n_rst+=(c==C_VW0); end
    end
    if (n_set!=0)                 op_type=OP_SET;
    else if (n_rst!=0)            op_type=OP_RESET;
    else if (n_src==1 && n_dst==1)op_type=OP_NOT;
    else if (n_src==2 && n_dst==1)op_type=OP_NOR;
    else                          op_type=OP_NOP;  // incl. source-less DST -> no-op by OTP
    op_is_write = (op_type==OP_SET)||(op_type==OP_RESET);
    violation = (col_op & row_op) | (n_dst>1) | (n_src>2);
  end
endmodule
