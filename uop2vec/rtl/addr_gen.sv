//////////////////////////////////////////////////////////////////////////////
/// File    : addr_gen.sv
/// Module  : addr_gen
///
/// Turns "base register + offset" operands into absolute line numbers:
/// abs = base[sel] + idx, computed on IDXW+1 bits so an overflow past the
/// last line stays visible to the checker (it never wraps into range).
/// For SET / RESET it also gives the inclusive range lo = min(src1, src2),
/// hi = max(src1, src2), so the two ends may come in either order.
//////////////////////////////////////////////////////////////////////////////

module addr_gen
  import uop2vec_pkg::*;
#(
  parameter int IDXW = 10
)
(
  // base registers from uop_regs
  input  logic [IDXW-1:0] base_dest,
  input  logic [IDXW-1:0] base_src1,
  input  logic [IDXW-1:0] base_src2,
  input  logic [IDXW-1:0] base_temp,

  // operand fields from uop_decode
  input  logic            dest_sel,
  input  logic [7:0]      dest_idx,
  input  logic [1:0]      src1_sel,
  input  logic [7:0]      src1_idx,
  input  logic [1:0]      src2_sel,
  input  logic [7:0]      src2_idx,

  // absolute line numbers
  output logic [IDXW:0]   dest_abs,
  output logic [IDXW:0]   src1_abs,
  output logic [IDXW:0]   src2_abs,

  // SET / RESET range (inclusive)
  output logic [IDXW:0]   rng_lo,
  output logic [IDXW:0]   rng_hi
);


  //////////////////////////////////////////////////////////////////////////
  /// Helper
  /// base (IDXW bits) + idx (8 bits), result on IDXW+1 bits
  //////////////////////////////////////////////////////////////////////////

  function automatic logic [IDXW:0] f_abs (
    input logic [IDXW-1:0] base,
    input logic [7:0]      idx
  );
    return {1'b0, base} + {{(IDXW-7){1'b0}}, idx};
  endfunction


  //////////////////////////////////////////////////////////////////////////
  /// Base select
  /// dest : 1-bit select  (DEST / TEMP)
  /// src  : 2-bit select  (DEST / SRC1 / SRC2 / TEMP)
  //////////////////////////////////////////////////////////////////////////

  logic [IDXW-1:0] dest_base;
  logic [IDXW-1:0] src1_base;
  logic [IDXW-1:0] src2_base;

  assign dest_base = (dest_sel == DSEL_TEMP) ? base_temp : base_dest;

  always_comb begin
    case (src1_sel)
      SEL_DEST : src1_base = base_dest;
      SEL_SRC1 : src1_base = base_src1;
      SEL_SRC2 : src1_base = base_src2;
      default  : src1_base = base_temp;   // SEL_TEMP
    endcase
  end

  always_comb begin
    case (src2_sel)
      SEL_DEST : src2_base = base_dest;
      SEL_SRC1 : src2_base = base_src1;
      SEL_SRC2 : src2_base = base_src2;
      default  : src2_base = base_temp;   // SEL_TEMP
    endcase
  end


  //////////////////////////////////////////////////////////////////////////
  /// Absolute line numbers
  //////////////////////////////////////////////////////////////////////////

  assign dest_abs = f_abs(dest_base, dest_idx);
  assign src1_abs = f_abs(src1_base, src1_idx);
  assign src2_abs = f_abs(src2_base, src2_idx);


  //////////////////////////////////////////////////////////////////////////
  /// SET / RESET range
  //////////////////////////////////////////////////////////////////////////

  assign rng_lo = (src1_abs <= src2_abs) ? src1_abs : src2_abs;
  assign rng_hi = (src1_abs <= src2_abs) ? src2_abs : src1_abs;


endmodule
