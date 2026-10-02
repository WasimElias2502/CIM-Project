//////////////////////////////////////////////////////////////////////////////
/// File    : uop_regs.sv
/// Module  : uop_regs
///
/// State of the Micro Instruction Block: the four base registers
/// (DEST, SRC1, SRC2, TEMP), the mask range + col flag and the crossbar
/// range. Only legal config ops write it; the write enables arrive already
/// qualified (accepted and not rejected). New values are visible in the
/// cycle right after the write, so a following memory op always sees them.
//////////////////////////////////////////////////////////////////////////////

module uop_regs
  import uop2vec_pkg::*;
#(
  parameter int IDXW = 10
)
(
  input  logic            clk,
  input  logic            rst_n,

  // qualified write enables (one per config op)
  input  logic            we_set_base,
  input  logic            we_inc_base,
  input  logic            we_set_mask,
  input  logic            we_set_cmask,

  // config fields from uop_decode
  input  logic            cfg_col,
  input  logic [1:0]      cfg_base_sel,
  input  logic [3:0]      cfg_inc_mask,
  input  logic [IDXW-1:0] cfg_lo,
  input  logic [IDXW-1:0] cfg_hi,

  // base registers
  output logic [IDXW-1:0] base_dest,
  output logic [IDXW-1:0] base_src1,
  output logic [IDXW-1:0] base_src2,
  output logic [IDXW-1:0] base_temp,

  // mask
  output logic [IDXW-1:0] m_start,
  output logic [IDXW-1:0] m_end,
  output logic            col,
  output logic            m_vld,

  // crossbar mask
  output logic [IDXW-1:0] c_start,
  output logic [IDXW-1:0] c_end,
  output logic            c_vld
);


  //////////////////////////////////////////////////////////////////////////
  /// Base registers
  /// SET_BASE : load cfg_lo into the register chosen by cfg_base_sel
  /// INC_BASE : +1 on every register whose cfg_inc_mask bit is set
  ///            (bit 0 DEST, 1 SRC1, 2 SRC2, 3 TEMP), wraps at 2^IDXW
  //////////////////////////////////////////////////////////////////////////

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      base_dest <= '0;
      base_src1 <= '0;
      base_src2 <= '0;
      base_temp <= '0;
    end
    else if (we_set_base) begin
      case (cfg_base_sel)
        SEL_DEST : base_dest <= cfg_lo;
        SEL_SRC1 : base_src1 <= cfg_lo;
        SEL_SRC2 : base_src2 <= cfg_lo;
        default  : base_temp <= cfg_lo;   // SEL_TEMP
      endcase
    end
    else if (we_inc_base) begin
      if (cfg_inc_mask[0]) base_dest <= base_dest + 1'b1;
      if (cfg_inc_mask[1]) base_src1 <= base_src1 + 1'b1;
      if (cfg_inc_mask[2]) base_src2 <= base_src2 + 1'b1;
      if (cfg_inc_mask[3]) base_temp <= base_temp + 1'b1;
    end
  end


  //////////////////////////////////////////////////////////////////////////
  /// Mask (SET_MASK)
  /// m_vld = 0 after reset: every mask-axis line is isolated until the
  /// first legal SET_MASK.
  //////////////////////////////////////////////////////////////////////////

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_start <= '0;
      m_end   <= '0;
      col     <= 1'b0;
      m_vld   <= 1'b0;
    end
    else if (we_set_mask) begin
      m_start <= cfg_lo;
      m_end   <= cfg_hi;
      col     <= cfg_col;
      m_vld   <= 1'b1;
    end
  end


  //////////////////////////////////////////////////////////////////////////
  /// Crossbar mask (SET_CMASK)
  /// c_vld = 0 after reset: no crossbar is active until the first legal
  /// SET_CMASK.
  //////////////////////////////////////////////////////////////////////////

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      c_start <= '0;
      c_end   <= '0;
      c_vld   <= 1'b0;
    end
    else if (we_set_cmask) begin
      c_start <= cfg_lo;
      c_end   <= cfg_hi;
      c_vld   <= 1'b1;
    end
  end


endmodule
