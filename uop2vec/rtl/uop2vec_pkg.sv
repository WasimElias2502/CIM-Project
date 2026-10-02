//////////////////////////////////////////////////////////////////////////////
/// File    : uop2vec_pkg.sv
/// Package : uop2vec_pkg
///
/// Shared constants of the Micro Instruction Block (uop2vec).
/// Holds the microinstruction opcodes, the operand-select encodings,
/// the 3-bit line codes driven to the memory array and the error-cause
/// bit positions. Line codes match memarray_pkg (same values) but use a
/// CODE_ prefix so both packages can be imported together in a testbench.
//////////////////////////////////////////////////////////////////////////////

package uop2vec_pkg;


  //////////////////////////////////////////////////////////////////////////
  /// Memory microinstruction opcodes  (uop[0] = 1, opcode in uop[2:1])
  //////////////////////////////////////////////////////////////////////////

  localparam logic [1:0] MOP_NOT   = 2'b00;
  localparam logic [1:0] MOP_NOR   = 2'b01;
  localparam logic [1:0] MOP_SET   = 2'b10;
  localparam logic [1:0] MOP_RESET = 2'b11;


  //////////////////////////////////////////////////////////////////////////
  /// Config microinstruction opcodes  (uop[0] = 0, opcode in uop[4:1])
  /// Any other type-0 opcode is a NOP.
  //////////////////////////////////////////////////////////////////////////

  localparam logic [3:0] COP_SET_CMASK = 4'b0011;
  localparam logic [3:0] COP_SET_MASK  = 4'b0100;
  localparam logic [3:0] COP_SET_BASE  = 4'b0101;
  localparam logic [3:0] COP_INC_BASE  = 4'b0110;


  //////////////////////////////////////////////////////////////////////////
  /// Base-register select
  /// SEL_*  : 2-bit select for src1 / src2 and for SET_BASE
  /// DSEL_* : 1-bit select for dest
  //////////////////////////////////////////////////////////////////////////

  localparam logic [1:0] SEL_DEST = 2'b00;
  localparam logic [1:0] SEL_SRC1 = 2'b01;
  localparam logic [1:0] SEL_SRC2 = 2'b10;
  localparam logic [1:0] SEL_TEMP = 2'b11;

  localparam logic       DSEL_DEST = 1'b0;
  localparam logic       DSEL_TEMP = 1'b1;


  //////////////////////////////////////////////////////////////////////////
  /// Line codes (3 bits per row / column, same values as memarray_pkg)
  //////////////////////////////////////////////////////////////////////////

  localparam logic [2:0] CODE_FLOAT = 3'b000;  // not involved / NOT-NOR mask active
  localparam logic [2:0] CODE_RESET = 3'b001;  // VW0 : write 0
  localparam logic [2:0] CODE_SET   = 3'b010;  // VW1 : write 1
  localparam logic [2:0] CODE_SRC   = 3'b100;  // VG  : source line
  localparam logic [2:0] CODE_DST   = 3'b101;  // GND : destination / SET-RESET mask active
  localparam logic [2:0] CODE_ISO   = 3'b111;  // isolated


  //////////////////////////////////////////////////////////////////////////
  /// Error-cause bit positions (err_cause[3:0])
  //////////////////////////////////////////////////////////////////////////

  localparam int ERR_OOR       = 0;  // memory op index out of range
  localparam int ERR_DST_SRC   = 1;  // dest equals a source (NOT / NOR)
  localparam int ERR_BAD_MASK  = 2;  // SET_MASK range outside the mask axis
  localparam int ERR_BAD_CMASK = 3;  // SET_CMASK range outside XBARS


endpackage
