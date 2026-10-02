module mem_cell import memarray_pkg::*; #(parameter bit RESET_VAL=1'b0)(
  input  logic clk, rst_n,
  input  logic [2:0] op_code,    // this cell's code on the operation axis
  input  logic [2:0] mask_code,  // this cell's code on the mask axis
  input  logic xbar_en,
  input  logic op_is_write,      // 1 during SET/RESET (selects mask meaning)
  input  logic trigger,          // from this line's OR (active axis)
  input  logic commit,           // S2 strobe
  output logic src_out,          // stored & is_src -> both source registers
  output logic bit_out);
  logic stored, is_src, is_dst, is_set, is_rst, mask_ok, act;
  assign is_src  = (op_code==C_VG);
  assign is_dst  = (op_code==C_GND);
  assign is_set  = (op_code==C_VW1);
  assign is_rst  = (op_code==C_VW0);
  assign mask_ok = op_is_write ? (mask_code==C_GND) : (mask_code==C_FLOAT);
  assign act     = xbar_en & mask_ok;
  assign src_out = stored & is_src & act;
  assign bit_out = stored;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) stored <= RESET_VAL;
    else if (commit & act) begin
      if (is_set)              stored <= 1'b1;
      else if (is_rst)         stored <= 1'b0;
      else if (is_dst&trigger) stored <= 1'b0; // OTP clear; never writes 1
    end
endmodule
