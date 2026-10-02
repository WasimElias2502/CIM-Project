//////////////////////////////////////////////////////////////////////////////
/// File    : vec_gen.sv
/// Module  : vec_gen
///
/// Builds the three vectors of one beat, purely combinational.
/// Operation axis : 101 dest, 100 source(s), 010 SET range, 001 RESET range.
/// Mask axis      : inside the mask 000 (NOT/NOR) or 101 (SET/RESET),
///                  outside (or no mask set yet) 111.
/// col = 0 puts the operation on columns, col = 1 on rows. Crossbar bit x
/// is 1 when x is inside the crossbar range (and a range has been set).
//////////////////////////////////////////////////////////////////////////////

module vec_gen
  import uop2vec_pkg::*;
#(
  parameter int ROWS  = 32,
  parameter int COLS  = 32,
  parameter int XBARS = 8,
  parameter int IDXW  = 10
)
(
  // memory op and its operands
  input  logic [1:0]        mem_op,
  input  logic [IDXW:0]     dest_abs,
  input  logic [IDXW:0]     src1_abs,
  input  logic [IDXW:0]     src2_abs,
  input  logic [IDXW:0]     rng_lo,
  input  logic [IDXW:0]     rng_hi,

  // mask and crossbar state from uop_regs
  input  logic [IDXW-1:0]   m_start,
  input  logic [IDXW-1:0]   m_end,
  input  logic              col,
  input  logic              m_vld,
  input  logic [IDXW-1:0]   c_start,
  input  logic [IDXW-1:0]   c_end,
  input  logic              c_vld,

  // beat vectors (line n = bits [3n+2 : 3n])
  output logic [3*COLS-1:0] col_vec,
  output logic [3*ROWS-1:0] row_vec,
  output logic [XBARS-1:0]  xbar_vec
);


  //////////////////////////////////////////////////////////////////////////
  /// Line-code functions
  //////////////////////////////////////////////////////////////////////////

  // code of one line on the operation axis
  function automatic logic [2:0] f_op_code (
    input logic [1:0]    op,
    input logic [IDXW:0] line,
    input logic [IDXW:0] d,
    input logic [IDXW:0] s1,
    input logic [IDXW:0] s2,
    input logic [IDXW:0] lo,
    input logic [IDXW:0] hi
  );
    logic in_rng;

    in_rng = (line >= lo) && (line <= hi);

    case (op)
      MOP_NOT : begin
        if      (line == d)  return CODE_DST;
        else if (line == s1) return CODE_SRC;
        else                 return CODE_FLOAT;
      end

      MOP_NOR : begin
        if      (line == d)                    return CODE_DST;
        else if ((line == s1) || (line == s2)) return CODE_SRC;
        else                                   return CODE_FLOAT;
      end

      MOP_SET : return in_rng ? CODE_SET   : CODE_FLOAT;

      default : return in_rng ? CODE_RESET : CODE_FLOAT;   // MOP_RESET
    endcase
  endfunction

  // code of one line on the mask axis
  function automatic logic [2:0] f_mask_code (
    input logic [1:0]      op,
    input logic [IDXW-1:0] line,
    input logic            vld,
    input logic [IDXW-1:0] lo,
    input logic [IDXW-1:0] hi
  );
    logic is_write;

    is_write = (op == MOP_SET) || (op == MOP_RESET);

    if (vld && (line >= lo) && (line <= hi))
      return is_write ? CODE_DST : CODE_FLOAT;
    else
      return CODE_ISO;
  endfunction


  //////////////////////////////////////////////////////////////////////////
  /// Mask and crossbar ranges (inclusive, either order)
  //////////////////////////////////////////////////////////////////////////

  logic [IDXW-1:0] mask_lo;
  logic [IDXW-1:0] mask_hi;
  logic [IDXW-1:0] xbar_lo;
  logic [IDXW-1:0] xbar_hi;

  assign mask_lo = (m_start <= m_end) ? m_start : m_end;
  assign mask_hi = (m_start <= m_end) ? m_end   : m_start;

  assign xbar_lo = (c_start <= c_end) ? c_start : c_end;
  assign xbar_hi = (c_start <= c_end) ? c_end   : c_start;


  //////////////////////////////////////////////////////////////////////////
  /// Per-line codes for both axes
  /// Each axis gets both an operation code and a mask code; col picks.
  //////////////////////////////////////////////////////////////////////////

  logic [COLS-1:0][2:0] col_op_code;
  logic [COLS-1:0][2:0] col_mask_code;
  logic [ROWS-1:0][2:0] row_op_code;
  logic [ROWS-1:0][2:0] row_mask_code;

  always_comb begin
    for (int c = 0; c < COLS; c++) begin
      col_op_code[c]   = f_op_code  (mem_op, c[IDXW:0],   dest_abs, src1_abs, src2_abs, rng_lo, rng_hi);
      col_mask_code[c] = f_mask_code(mem_op, c[IDXW-1:0], m_vld, mask_lo, mask_hi);
    end
  end

  always_comb begin
    for (int r = 0; r < ROWS; r++) begin
      row_op_code[r]   = f_op_code  (mem_op, r[IDXW:0],   dest_abs, src1_abs, src2_abs, rng_lo, rng_hi);
      row_mask_code[r] = f_mask_code(mem_op, r[IDXW-1:0], m_vld, mask_lo, mask_hi);
    end
  end


  //////////////////////////////////////////////////////////////////////////
  /// Axis selection
  /// col = 0 : operation on columns, mask on rows
  /// col = 1 : operation on rows,    mask on columns
  //////////////////////////////////////////////////////////////////////////

  assign col_vec = col ? col_mask_code : col_op_code;
  assign row_vec = col ? row_op_code   : row_mask_code;


  //////////////////////////////////////////////////////////////////////////
  /// Crossbar vector
  //////////////////////////////////////////////////////////////////////////

  always_comb begin
    for (int x = 0; x < XBARS; x++) begin
      xbar_vec[x] = c_vld && (x[IDXW-1:0] >= xbar_lo) && (x[IDXW-1:0] <= xbar_hi);
    end
  end


endmodule
