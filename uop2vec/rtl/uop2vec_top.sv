//////////////////////////////////////////////////////////////////////////////
/// File    : uop2vec_top.sv
/// Module  : uop2vec_top
///
/// Micro Instruction Block: takes a stream of 32-bit microinstructions and
/// drives col / row / crossbar vectors into memarray_top, one beat per
/// legal memory op. Config ops set the masks and base registers; errors
/// are reported on err_*. Translation is one combinational cycle into one
/// output register, no pipeline. Chain: decode -> regs -> addr_gen ->
/// checker -> vec_gen -> beat_out. See the uop2vec spec for full detail.
//////////////////////////////////////////////////////////////////////////////

module uop2vec_top
  import uop2vec_pkg::*;
#(
  parameter int ROWS     = 32,
  parameter int COLS     = 32,
  parameter int XBARS    = 8,
  parameter int IDXW     = 10,   // fixed by the microinstruction encoding
  parameter int BEAT_GAP = 3     // min cycles between beats, >= 1
)
(
  input  logic              clk,
  input  logic              rst_n,

  // microinstruction input (AXI-Stream slave)
  input  logic [31:0]       s_uop_tdata,
  input  logic              s_uop_tvalid,
  output logic              s_uop_tready,

  // column vector (AXI-Stream master)
  output logic [3*COLS-1:0] m_col_tdata,
  output logic              m_col_tvalid,
  input  logic              m_col_tready,    // ignored, tie to 1

  // row vector (AXI-Stream master)
  output logic [3*ROWS-1:0] m_row_tdata,
  output logic              m_row_tvalid,
  input  logic              m_row_tready,    // ignored, tie to 1

  // crossbar vector (AXI-Stream master)
  output logic [XBARS-1:0]  m_xbar_tdata,
  output logic              m_xbar_tvalid,
  input  logic              m_xbar_tready,   // ignored, tie to 1

  // status
  output logic              err_sticky,
  output logic [3:0]        err_cause,
  output logic              err_pulse,
  input  logic              err_clr,

  // debug (spec section 3): current register values, for verification
  output logic [IDXW-1:0]   dbg_dest,
  output logic [IDXW-1:0]   dbg_src1,
  output logic [IDXW-1:0]   dbg_src2,
  output logic [IDXW-1:0]   dbg_temp,
  output logic [IDXW-1:0]   dbg_m_start,
  output logic [IDXW-1:0]   dbg_m_end,
  output logic              dbg_col,
  output logic [IDXW-1:0]   dbg_c_start,
  output logic [IDXW-1:0]   dbg_c_end,
  output logic              dbg_m_vld,
  output logic              dbg_c_vld
);


  //////////////////////////////////////////////////////////////////////////
  /// Parameter checks (simulation only)
  //////////////////////////////////////////////////////////////////////////

  // synthesis translate_off
  initial begin
    if (IDXW != 10)
      $fatal(1, "uop2vec_top: IDXW must be 10 (fixed by the encoding)");

    if (BEAT_GAP < 1)
      $fatal(1, "uop2vec_top: BEAT_GAP must be >= 1");

    if ((ROWS > 2**IDXW) || (COLS > 2**IDXW) || (XBARS > 2**IDXW))
      $fatal(1, "uop2vec_top: ROWS, COLS and XBARS must be <= 2**IDXW");
  end
  // synthesis translate_on


  //////////////////////////////////////////////////////////////////////////
  /// Internal signals
  //////////////////////////////////////////////////////////////////////////

  // uop_decode
  logic              dec_is_mem;
  logic              dec_is_set_cmask;
  logic              dec_is_set_mask;
  logic              dec_is_set_base;
  logic              dec_is_inc_base;
  logic [1:0]        dec_mem_op;
  logic              dec_dest_sel;
  logic [7:0]        dec_dest_idx;
  logic [1:0]        dec_src1_sel;
  logic [7:0]        dec_src1_idx;
  logic [1:0]        dec_src2_sel;
  logic [7:0]        dec_src2_idx;
  logic              dec_cfg_col;
  logic [1:0]        dec_cfg_base_sel;
  logic [3:0]        dec_cfg_inc_mask;
  logic [IDXW-1:0]   dec_cfg_lo;
  logic [IDXW-1:0]   dec_cfg_hi;

  // uop_regs
  logic [IDXW-1:0]   reg_base_dest;
  logic [IDXW-1:0]   reg_base_src1;
  logic [IDXW-1:0]   reg_base_src2;
  logic [IDXW-1:0]   reg_base_temp;
  logic [IDXW-1:0]   reg_m_start;
  logic [IDXW-1:0]   reg_m_end;
  logic              reg_col;
  logic              reg_m_vld;
  logic [IDXW-1:0]   reg_c_start;
  logic [IDXW-1:0]   reg_c_end;
  logic              reg_c_vld;

  // addr_gen
  logic [IDXW:0]     adr_dest_abs;
  logic [IDXW:0]     adr_src1_abs;
  logic [IDXW:0]     adr_src2_abs;
  logic [IDXW:0]     adr_rng_lo;
  logic [IDXW:0]     adr_rng_hi;

  // uop_checker
  logic              chk_mem_legal;
  logic              chk_mask_legal;
  logic              chk_cmask_legal;

  // vec_gen
  logic [3*COLS-1:0] vec_col;
  logic [3*ROWS-1:0] vec_row;
  logic [XBARS-1:0]  vec_xbar;

  // beat_out
  logic              beat_valid;

  // handshake / write enables
  logic              accept;
  logic              beat_fire;
  logic              we_set_base;
  logic              we_inc_base;
  logic              we_set_mask;
  logic              we_set_cmask;


  //////////////////////////////////////////////////////////////////////////
  /// Handshake and write enables
  /// accept    : a word is taken this cycle
  /// beat_fire : accepted legal memory op -> one beat
  /// we_*      : accepted legal config op -> register write
  //////////////////////////////////////////////////////////////////////////

  assign accept       = s_uop_tvalid & s_uop_tready;

  assign beat_fire    = accept & chk_mem_legal;

  assign we_set_base  = accept & dec_is_set_base;
  assign we_inc_base  = accept & dec_is_inc_base;
  assign we_set_mask  = accept & chk_mask_legal;
  assign we_set_cmask = accept & chk_cmask_legal;


  //////////////////////////////////////////////////////////////////////////
  /// Decode
  //////////////////////////////////////////////////////////////////////////

  uop_decode u_decode (
    .uop          (s_uop_tdata),
    .is_mem       (dec_is_mem),
    .is_set_cmask (dec_is_set_cmask),
    .is_set_mask  (dec_is_set_mask),
    .is_set_base  (dec_is_set_base),
    .is_inc_base  (dec_is_inc_base),
    .mem_op       (dec_mem_op),
    .dest_sel     (dec_dest_sel),
    .dest_idx     (dec_dest_idx),
    .src1_sel     (dec_src1_sel),
    .src1_idx     (dec_src1_idx),
    .src2_sel     (dec_src2_sel),
    .src2_idx     (dec_src2_idx),
    .cfg_col      (dec_cfg_col),
    .cfg_base_sel (dec_cfg_base_sel),
    .cfg_inc_mask (dec_cfg_inc_mask),
    .cfg_lo       (dec_cfg_lo),
    .cfg_hi       (dec_cfg_hi)
  );


  //////////////////////////////////////////////////////////////////////////
  /// Registers (bases, mask, crossbar mask)
  //////////////////////////////////////////////////////////////////////////

  uop_regs #(
    .IDXW (IDXW)
  ) u_regs (
    .clk          (clk),
    .rst_n        (rst_n),
    .we_set_base  (we_set_base),
    .we_inc_base  (we_inc_base),
    .we_set_mask  (we_set_mask),
    .we_set_cmask (we_set_cmask),
    .cfg_col      (dec_cfg_col),
    .cfg_base_sel (dec_cfg_base_sel),
    .cfg_inc_mask (dec_cfg_inc_mask),
    .cfg_lo       (dec_cfg_lo),
    .cfg_hi       (dec_cfg_hi),
    .base_dest    (reg_base_dest),
    .base_src1    (reg_base_src1),
    .base_src2    (reg_base_src2),
    .base_temp    (reg_base_temp),
    .m_start      (reg_m_start),
    .m_end        (reg_m_end),
    .col          (reg_col),
    .m_vld        (reg_m_vld),
    .c_start      (reg_c_start),
    .c_end        (reg_c_end),
    .c_vld        (reg_c_vld)
  );


  //////////////////////////////////////////////////////////////////////////
  /// Address generation
  //////////////////////////////////////////////////////////////////////////

  addr_gen #(
    .IDXW (IDXW)
  ) u_addr_gen (
    .base_dest (reg_base_dest),
    .base_src1 (reg_base_src1),
    .base_src2 (reg_base_src2),
    .base_temp (reg_base_temp),
    .dest_sel  (dec_dest_sel),
    .dest_idx  (dec_dest_idx),
    .src1_sel  (dec_src1_sel),
    .src1_idx  (dec_src1_idx),
    .src2_sel  (dec_src2_sel),
    .src2_idx  (dec_src2_idx),
    .dest_abs  (adr_dest_abs),
    .src1_abs  (adr_src1_abs),
    .src2_abs  (adr_src2_abs),
    .rng_lo    (adr_rng_lo),
    .rng_hi    (adr_rng_hi)
  );


  //////////////////////////////////////////////////////////////////////////
  /// Checker and error status
  //////////////////////////////////////////////////////////////////////////

  uop_checker #(
    .ROWS  (ROWS),
    .COLS  (COLS),
    .XBARS (XBARS),
    .IDXW  (IDXW)
  ) u_checker (
    .clk          (clk),
    .rst_n        (rst_n),
    .accept       (accept),
    .err_clr      (err_clr),
    .is_mem       (dec_is_mem),
    .mem_op       (dec_mem_op),
    .is_set_mask  (dec_is_set_mask),
    .is_set_cmask (dec_is_set_cmask),
    .cfg_col      (dec_cfg_col),
    .cfg_lo       (dec_cfg_lo),
    .cfg_hi       (dec_cfg_hi),
    .dest_abs     (adr_dest_abs),
    .src1_abs     (adr_src1_abs),
    .src2_abs     (adr_src2_abs),
    .rng_hi       (adr_rng_hi),
    .col          (reg_col),
    .mem_legal    (chk_mem_legal),
    .mask_legal   (chk_mask_legal),
    .cmask_legal  (chk_cmask_legal),
    .err_sticky   (err_sticky),
    .err_cause    (err_cause),
    .err_pulse    (err_pulse)
  );


  //////////////////////////////////////////////////////////////////////////
  /// Vector generation
  //////////////////////////////////////////////////////////////////////////

  vec_gen #(
    .ROWS  (ROWS),
    .COLS  (COLS),
    .XBARS (XBARS),
    .IDXW  (IDXW)
  ) u_vec_gen (
    .mem_op   (dec_mem_op),
    .dest_abs (adr_dest_abs),
    .src1_abs (adr_src1_abs),
    .src2_abs (adr_src2_abs),
    .rng_lo   (adr_rng_lo),
    .rng_hi   (adr_rng_hi),
    .m_start  (reg_m_start),
    .m_end    (reg_m_end),
    .col      (reg_col),
    .m_vld    (reg_m_vld),
    .c_start  (reg_c_start),
    .c_end    (reg_c_end),
    .c_vld    (reg_c_vld),
    .col_vec  (vec_col),
    .row_vec  (vec_row),
    .xbar_vec (vec_xbar)
  );


  //////////////////////////////////////////////////////////////////////////
  /// Output stage and pacing
  //////////////////////////////////////////////////////////////////////////

  beat_out #(
    .ROWS     (ROWS),
    .COLS     (COLS),
    .XBARS    (XBARS),
    .BEAT_GAP (BEAT_GAP)
  ) u_beat_out (
    .clk        (clk),
    .rst_n      (rst_n),
    .beat_fire  (beat_fire),
    .col_vec    (vec_col),
    .row_vec    (vec_row),
    .xbar_vec   (vec_xbar),
    .col_data   (m_col_tdata),
    .row_data   (m_row_tdata),
    .xbar_data  (m_xbar_tdata),
    .beat_valid (beat_valid),
    .uop_ready  (s_uop_tready)
  );


  //////////////////////////////////////////////////////////////////////////
  /// Output valids
  /// The three streams always carry one beat together.
  /// m_*_tready are ignored: memarray_top has no back-pressure.
  //////////////////////////////////////////////////////////////////////////

  assign m_col_tvalid  = beat_valid;
  assign m_row_tvalid  = beat_valid;
  assign m_xbar_tvalid = beat_valid;


  //////////////////////////////////////////////////////////////////////////
  /// Debug outputs (spec section 3): the registers of uop_regs, unchanged
  //////////////////////////////////////////////////////////////////////////

  assign dbg_dest    = reg_base_dest;
  assign dbg_src1    = reg_base_src1;
  assign dbg_src2    = reg_base_src2;
  assign dbg_temp    = reg_base_temp;
  assign dbg_m_start = reg_m_start;
  assign dbg_m_end   = reg_m_end;
  assign dbg_col     = reg_col;
  assign dbg_c_start = reg_c_start;
  assign dbg_c_end   = reg_c_end;
  assign dbg_m_vld   = reg_m_vld;
  assign dbg_c_vld   = reg_c_vld;


endmodule
