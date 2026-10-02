//////////////////////////////////////////////////////////////////////////////
/// File    : uop_decode.sv
/// Module  : uop_decode
///
/// Splits a 32-bit microinstruction into named fields and flags its kind.
/// Bit 0 = 1 : memory op (NOT / NOR / SET / RESET), fields as in the ROM.
/// Bit 0 = 0 : config op (SET_CMASK / SET_MASK / SET_BASE / INC_BASE),
///             every other type-0 opcode is a NOP (all is_* flags low).
/// Purely combinational, no state. Field meaning depends on the kind.
//////////////////////////////////////////////////////////////////////////////

module uop_decode
  import uop2vec_pkg::*;
(
  input  logic [31:0] uop,

  // kind
  output logic        is_mem,
  output logic        is_set_cmask,
  output logic        is_set_mask,
  output logic        is_set_base,
  output logic        is_inc_base,

  // memory-op fields
  output logic [1:0]  mem_op,
  output logic        dest_sel,
  output logic [7:0]  dest_idx,
  output logic [1:0]  src1_sel,
  output logic [7:0]  src1_idx,
  output logic [1:0]  src2_sel,
  output logic [7:0]  src2_idx,

  // config-op fields
  output logic        cfg_col,
  output logic [1:0]  cfg_base_sel,
  output logic [3:0]  cfg_inc_mask,
  output logic [9:0]  cfg_lo,
  output logic [9:0]  cfg_hi
);


  //////////////////////////////////////////////////////////////////////////
  /// Kind
  //////////////////////////////////////////////////////////////////////////

  logic [3:0] cfg_opcode;

  assign cfg_opcode   = uop[4:1];

  assign is_mem       =  uop[0];
  assign is_set_cmask = ~uop[0] & (cfg_opcode == COP_SET_CMASK);
  assign is_set_mask  = ~uop[0] & (cfg_opcode == COP_SET_MASK);
  assign is_set_base  = ~uop[0] & (cfg_opcode == COP_SET_BASE);
  assign is_inc_base  = ~uop[0] & (cfg_opcode == COP_INC_BASE);


  //////////////////////////////////////////////////////////////////////////
  /// Memory-op fields
  /// [2:1] op | [3] dest_sel | [11:4] dest_idx | [13:12] src1_sel
  /// [21:14] src1_idx | [23:22] src2_sel | [31:24] src2_idx
  //////////////////////////////////////////////////////////////////////////

  assign mem_op   = uop[2:1];
  assign dest_sel = uop[3];
  assign dest_idx = uop[11:4];
  assign src1_sel = uop[13:12];
  assign src1_idx = uop[21:14];
  assign src2_sel = uop[23:22];
  assign src2_idx = uop[31:24];


  //////////////////////////////////////////////////////////////////////////
  /// Config-op fields
  /// [6] col (SET_MASK) | [6:5] reg (SET_BASE) | [8:5] inc mask (INC_BASE)
  /// [16:7] start / cstart / value | [26:17] end / cend
  //////////////////////////////////////////////////////////////////////////

  assign cfg_col      = uop[6];
  assign cfg_base_sel = uop[6:5];
  assign cfg_inc_mask = uop[8:5];
  assign cfg_lo       = uop[16:7];
  assign cfg_hi       = uop[26:17];


endmodule
