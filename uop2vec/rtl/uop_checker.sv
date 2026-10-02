//////////////////////////////////////////////////////////////////////////////
/// File    : uop_checker.sv
/// Module  : uop_checker
///
/// Decides if the current microinstruction is legal and keeps the error
/// status. Memory ops: index out of range, dest equal to a source.
/// Config ops: SET_MASK / SET_CMASK range outside its axis. A rejected
/// word produces no beat and no register write; its cause is ORed into
/// err_cause (sticky until err_clr or reset) and err_pulse fires 1 cycle.
//////////////////////////////////////////////////////////////////////////////

module uop_checker
  import uop2vec_pkg::*;
#(
  parameter int ROWS  = 32,
  parameter int COLS  = 32,
  parameter int XBARS = 8,
  parameter int IDXW  = 10
)
(
  input  logic            clk,
  input  logic            rst_n,
  input  logic            accept,        // word taken this cycle
  input  logic            err_clr,

  // decoded word
  input  logic            is_mem,
  input  logic [1:0]      mem_op,
  input  logic            is_set_mask,
  input  logic            is_set_cmask,
  input  logic            cfg_col,
  input  logic [IDXW-1:0] cfg_lo,
  input  logic [IDXW-1:0] cfg_hi,

  // absolute operands from addr_gen
  input  logic [IDXW:0]   dest_abs,
  input  logic [IDXW:0]   src1_abs,
  input  logic [IDXW:0]   src2_abs,
  input  logic [IDXW:0]   rng_hi,

  // current axis flag from uop_regs
  input  logic            col,

  // legality of the current word (combinational)
  output logic            mem_legal,
  output logic            mask_legal,
  output logic            cmask_legal,

  // error status (registered)
  output logic            err_sticky,
  output logic [3:0]      err_cause,
  output logic            err_pulse
);


  //////////////////////////////////////////////////////////////////////////
  /// Axis sizes on IDXW+1 bits
  /// n_op   : operation-axis size for the current col
  /// n_mask : mask-axis size for the col carried by SET_MASK itself
  //////////////////////////////////////////////////////////////////////////

  localparam logic [IDXW:0] ROWS_W  = ROWS[IDXW:0];
  localparam logic [IDXW:0] COLS_W  = COLS[IDXW:0];
  localparam logic [IDXW:0] XBARS_W = XBARS[IDXW:0];

  logic [IDXW:0] n_op;
  logic [IDXW:0] n_mask;

  assign n_op   = col     ? ROWS_W : COLS_W;
  assign n_mask = cfg_col ? COLS_W : ROWS_W;


  //////////////////////////////////////////////////////////////////////////
  /// Memory-op checks
  /// NOT       : dest, src1 in range, dest != src1
  /// NOR       : dest, src1, src2 in range, dest != src1, dest != src2
  /// SET/RESET : range end (hi) in range; lo <= hi by construction
  //////////////////////////////////////////////////////////////////////////

  logic oor;
  logic dst_src;

  always_comb begin
    case (mem_op)
      MOP_NOT : begin
        oor     = (dest_abs >= n_op) | (src1_abs >= n_op);
        dst_src = (dest_abs == src1_abs);
      end

      MOP_NOR : begin
        oor     = (dest_abs >= n_op) | (src1_abs >= n_op) | (src2_abs >= n_op);
        dst_src = (dest_abs == src1_abs) | (dest_abs == src2_abs);
      end

      default : begin   // MOP_SET, MOP_RESET
        oor     = (rng_hi >= n_op);
        dst_src = 1'b0;
      end
    endcase
  end


  //////////////////////////////////////////////////////////////////////////
  /// Config-op checks
  /// The larger end of the range must be inside its axis.
  //////////////////////////////////////////////////////////////////////////

  logic [IDXW-1:0] cfg_max;
  logic            bad_mask;
  logic            bad_cmask;

  assign cfg_max   = (cfg_lo >= cfg_hi) ? cfg_lo : cfg_hi;

  assign bad_mask  = ({1'b0, cfg_max} >= n_mask);
  assign bad_cmask = ({1'b0, cfg_max} >= XBARS_W);


  //////////////////////////////////////////////////////////////////////////
  /// Error bits and legal flags of the current word
  //////////////////////////////////////////////////////////////////////////

  logic [3:0] err_bits;

  assign err_bits[ERR_OOR]       = is_mem       & oor;
  assign err_bits[ERR_DST_SRC]   = is_mem       & dst_src;
  assign err_bits[ERR_BAD_MASK]  = is_set_mask  & bad_mask;
  assign err_bits[ERR_BAD_CMASK] = is_set_cmask & bad_cmask;

  assign mem_legal   = is_mem       & ~oor & ~dst_src;
  assign mask_legal  = is_set_mask  & ~bad_mask;
  assign cmask_legal = is_set_cmask & ~bad_cmask;


  //////////////////////////////////////////////////////////////////////////
  /// Error status
  /// err_cause : sticky OR of causes; a new error in the same cycle as
  ///             err_clr wins (it is kept, older causes are cleared)
  /// err_pulse : 1 for the cycle after each rejected word
  //////////////////////////////////////////////////////////////////////////

  logic [3:0] err_now;

  assign err_now = accept ? err_bits : 4'b0000;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      err_cause <= 4'b0000;
      err_pulse <= 1'b0;
    end
    else begin
      err_pulse <= |err_now;

      if (err_clr) err_cause <= err_now;
      else         err_cause <= err_cause | err_now;
    end
  end

  assign err_sticky = |err_cause;


endmodule
