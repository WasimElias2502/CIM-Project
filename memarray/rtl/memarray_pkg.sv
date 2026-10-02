package memarray_pkg;
  typedef enum logic [2:0] {
    C_FLOAT=3'b000, C_VW0=3'b001, C_VW1=3'b010, C_VREAD=3'b011,
    C_VG=3'b100, C_GND=3'b101, C_RREF=3'b110, C_ISO=3'b111 } code_e;
  typedef enum logic [2:0] {OP_NOP, OP_NOT, OP_NOR, OP_SET, OP_RESET} op_e;
  typedef enum logic {AXIS_COL=1'b0, AXIS_ROW=1'b1} axis_e;
endpackage
