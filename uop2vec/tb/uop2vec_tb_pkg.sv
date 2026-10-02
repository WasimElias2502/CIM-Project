////////////////////////////////////////////////////////////////////////
// uop2vec_tb_pkg.sv
// Shared verification code for uop2vec_top.
// Everything here is written from the spec ("uop2vec - Design &
// Verification Spec", 25 Sep 2026), NOT from the RTL, so the testbenches
// check the RTL against the spec.
//
//   * code / opcode constants ........ spec sections 4 and 6
//   * enc_* functions ................ a tiny assembler (spec 4.1 / 4.2)
//   * uop2vec_model .................. cycle-level reference model of
//                                      uop2vec_top (spec 5, 6, 7, 8),
//                                      plus an optional memory model with
//                                      OTP semantics (integration test)
//   * rnd_* functions ................ random stimulus
//   * g_* functions .................. gate macros (NOT/NOR/OR/AND/XOR)
//                                      that always SET the destination
//                                      first, as the OTP array requires
////////////////////////////////////////////////////////////////////////
package uop2vec_tb_pkg;

  //////////////////////////////////////////////////////////////////////
  // 3-bit line codes (spec 6). Defined here on purpose instead of
  // importing memarray_pkg, so the standalone test does not depend on
  // the array's package.
  //////////////////////////////////////////////////////////////////////
  localparam logic [2:0] C_FLOAT = 3'b000;
  localparam logic [2:0] C_VW0   = 3'b001;
  localparam logic [2:0] C_VW1   = 3'b010;
  localparam logic [2:0] C_VG    = 3'b100;
  localparam logic [2:0] C_GND   = 3'b101;
  localparam logic [2:0] C_ISO   = 3'b111;

  //////////////////////////////////////////////////////////////////////
  // Memory op field values (spec 4.1)
  //////////////////////////////////////////////////////////////////////
  localparam logic [1:0] OP_NOT   = 2'b00;
  localparam logic [1:0] OP_NOR   = 2'b01;
  localparam logic [1:0] OP_SET   = 2'b10;
  localparam logic [1:0] OP_RESET = 2'b11;

  localparam logic [1:0] SEL_DEST = 2'd0;
  localparam logic [1:0] SEL_SRC1 = 2'd1;
  localparam logic [1:0] SEL_SRC2 = 2'd2;
  localparam logic [1:0] SEL_TEMP = 2'd3;

  //////////////////////////////////////////////////////////////////////
  // Config op codes in bits [4:1] (spec 4.2)
  //////////////////////////////////////////////////////////////////////
  localparam logic [3:0] CFG_SET_CMASK = 4'b0011;
  localparam logic [3:0] CFG_SET_MASK  = 4'b0100;
  localparam logic [3:0] CFG_SET_BASE  = 4'b0101;
  localparam logic [3:0] CFG_INC_BASE  = 4'b0110;

  //////////////////////////////////////////////////////////////////////
  // err_cause bit positions (spec 8)
  //////////////////////////////////////////////////////////////////////
  localparam int ERR_RANGE  = 0;   // index out of range
  localparam int ERR_DSTSRC = 1;   // dest equals a source
  localparam int ERR_MASK   = 2;   // bad SET_MASK
  localparam int ERR_CMASK  = 3;   // bad SET_CMASK

  function automatic int imin(input int a, input int b);
    return (a < b) ? a : b;
  endfunction

  function automatic int imax(input int a, input int b);
    return (a > b) ? a : b;
  endfunction

  // Printable names (returned as string type, so %s prints them cleanly)
  function automatic string okfail(input bit ok);
    if (ok) return "ok";
    return "FAILED";
  endfunction

  function automatic string op_name(input int op);
    case (op)
      0:       return "NOT";
      1:       return "NOR";
      2:       return "SET";
      default: return "RESET";
    endcase
  endfunction

  ////////////////////////////////////////////////////////////////////////
  // Encoders (the assembler).
  // Unlisted bits are written as 0, as the spec asks.
  //
  //   op     - OP_NOT / OP_NOR / OP_SET / OP_RESET
  //   dsel   - 0 = DEST, 1 = TEMP            (dest base register)
  //   didx   - dest offset 0..255
  //   s1sel  - SEL_DEST/SRC1/SRC2/TEMP       (source 1 base register)
  //   s1idx  - source 1 offset 0..255
  //   s2sel  - same, for source 2
  //   s2idx  - source 2 offset 0..255
  ////////////////////////////////////////////////////////////////////////
  function automatic logic [31:0] enc_mem(input logic [1:0] op,
                                          input bit         dsel,
                                          input int         didx,
                                          input logic [1:0] s1sel,
                                          input int         s1idx,
                                          input logic [1:0] s2sel,
                                          input int         s2idx);
    logic [31:0] w;
    w        = '0;
    w[0]     = 1'b1;
    w[2:1]   = op;
    w[3]     = dsel;
    w[11:4]  = didx[7:0];
    w[13:12] = s1sel;
    w[21:14] = s1idx[7:0];
    w[23:22] = s2sel;
    w[31:24] = s2idx[7:0];
    return w;
  endfunction

  // dest <- NOT src1 (src2 fields written as 0, they are ignored)
  function automatic logic [31:0] enc_not(input bit dsel, input int didx,
                                          input logic [1:0] s1sel, input int s1idx);
    return enc_mem(OP_NOT, dsel, didx, s1sel, s1idx, SEL_DEST, 0);
  endfunction

  // dest <- NOR(src1, src2)
  function automatic logic [31:0] enc_nor(input bit dsel, input int didx,
                                          input logic [1:0] s1sel, input int s1idx,
                                          input logic [1:0] s2sel, input int s2idx);
    return enc_mem(OP_NOR, dsel, didx, s1sel, s1idx, s2sel, s2idx);
  endfunction

  // SET the range between (asel+aidx) and (bsel+bidx), both ends inclusive
  function automatic logic [31:0] enc_set(input logic [1:0] asel, input int aidx,
                                          input logic [1:0] bsel, input int bidx);
    return enc_mem(OP_SET, 1'b0, 0, asel, aidx, bsel, bidx);
  endfunction

  // RESET the range between (asel+aidx) and (bsel+bidx), both ends inclusive
  function automatic logic [31:0] enc_reset(input logic [1:0] asel, input int aidx,
                                            input logic [1:0] bsel, input int bidx);
    return enc_mem(OP_RESET, 1'b0, 0, asel, aidx, bsel, bidx);
  endfunction

  function automatic logic [31:0] enc_cfg(input logic [3:0] opc);
    logic [31:0] w;
    w      = '0;
    w[4:1] = opc;
    return w;
  endfunction

  // Crossbars cs..ce active
  function automatic logic [31:0] enc_set_cmask(input int cs, input int ce);
    logic [31:0] w;
    w        = enc_cfg(CFG_SET_CMASK);
    w[16:7]  = cs[9:0];
    w[26:17] = ce[9:0];
    return w;
  endfunction

  // Mask lines st..en active; col = 0: mask on rows / ops on columns,
  // col = 1: swapped
  function automatic logic [31:0] enc_set_mask(input int st, input int en, input bit col);
    logic [31:0] w;
    w        = enc_cfg(CFG_SET_MASK);
    w[6]     = col;
    w[16:7]  = st[9:0];
    w[26:17] = en[9:0];
    return w;
  endfunction

  // Base register rsel <- val
  function automatic logic [31:0] enc_set_base(input logic [1:0] rsel, input int val);
    logic [31:0] w;
    w       = enc_cfg(CFG_SET_BASE);
    w[6:5]  = rsel;
    w[16:7] = val[9:0];
    return w;
  endfunction

  // +1 on every selected base register
  function automatic logic [31:0] enc_inc_base(input bit d, input bit s1,
                                               input bit s2, input bit t);
    logic [31:0] w;
    w    = enc_cfg(CFG_INC_BASE);
    w[5] = d;
    w[6] = s1;
    w[7] = s2;
    w[8] = t;
    return w;
  endfunction

  ////////////////////////////////////////////////////////////////////////
  // check_encoders
  // Compares the encoders against the hex values printed in the spec
  // (tables 4.3 and 9). Returns the number of mismatches. A mismatch
  // means either the encoders or the spec table is wrong.
  ////////////////////////////////////////////////////////////////////////
  function automatic int check_encoders();
    int bad;
    bad = 0;
    if (enc_set_cmask(0, 1)              !== 32'h00020006) begin bad++; $display("ENCODER MISMATCH: SET_CMASK 0 1");        end
    if (enc_set_mask(0, 3, 1'b0)         !== 32'h00060008) begin bad++; $display("ENCODER MISMATCH: SET_MASK 0 3 col=0");   end
    if (enc_set_mask(0, 7, 1'b1)         !== 32'h000E0048) begin bad++; $display("ENCODER MISMATCH: SET_MASK 0 7 col=1");   end
    if (enc_set_base(SEL_DEST, 2)        !== 32'h0000010A) begin bad++; $display("ENCODER MISMATCH: SET_BASE DEST 2");      end
    if (enc_set_base(SEL_SRC1, 5)        !== 32'h000002AA) begin bad++; $display("ENCODER MISMATCH: SET_BASE SRC1 5");      end
    if (enc_set_base(SEL_DEST, 7)        !== 32'h0000038A) begin bad++; $display("ENCODER MISMATCH: SET_BASE DEST 7");      end
    if (enc_inc_base(1, 1, 0, 0)         !== 32'h0000006C) begin bad++; $display("ENCODER MISMATCH: INC_BASE DEST+SRC1");   end
    if (enc_set(SEL_DEST, 0, SEL_DEST, 0)!== 32'h00000005) begin bad++; $display("ENCODER MISMATCH: SET DEST+0..DEST+0");   end
    if (enc_not(1'b0, 0, SEL_SRC1, 0)    !== 32'h00001001) begin bad++; $display("ENCODER MISMATCH: NOT DEST+0 <- SRC1+0"); end
    if (enc_not(1'b0, 1, SEL_SRC1, 0)    !== 32'h00001011) begin bad++; $display("ENCODER MISMATCH: NOT DEST+1 <- SRC1+0"); end
    if (enc_not(1'b0, 0, SEL_DEST, 0)    !== 32'h00000001) begin bad++; $display("ENCODER MISMATCH: NOT DEST+0 <- DEST+0"); end
    return bad;
  endfunction

  ////////////////////////////////////////////////////////////////////////
  // uop2vec_model
  // Cycle-level reference model of uop2vec_top.
  //
  // Call apply() once per clock cycle, at a point where the DUT outputs
  // for that cycle are stable (the testbenches use the falling edge),
  // passing what happened at the rising edge that started the cycle:
  //   acc - a word was accepted (s_uop_tvalid & s_uop_tready)
  //   w   - that word
  //   clr - err_clr was 1
  // After apply(), the exp_* fields hold what every DUT output must show
  // in this cycle, and base/m_*/c_*/col/*_vld hold the dbg_* values.
  //
  // Interpretation choices where the spec is not explicit (listed in
  // README.md as well):
  //   I1 err_clr and a new error on the same edge:
  //      err_cause <= (err_clr ? 0 : err_cause) | new_cause
  //   I2 a word can set two cause bits at once (for example NOR whose dest
  //      is both out of range and equal to a source) - both bits are set.
  ////////////////////////////////////////////////////////////////////////
  class uop2vec_model #(int ROWS = 32, int COLS = 32, int XBARS = 8, int BEAT_GAP = 2);

    //////////////////////////////////////////////////////////////////////
    // Architectural state (spec 5)
    // base[0] DEST, base[1] SRC1, base[2] SRC2, base[3] TEMP (10-bit)
    //////////////////////////////////////////////////////////////////////
    int         base [4];
    int         m_start, m_end, c_start, c_end;
    bit         col, m_vld, c_vld;
    logic [3:0] err_cause;
    bit         err_sticky;

    //////////////////////////////////////////////////////////////////////
    // Predicted DUT outputs for the current cycle
    //////////////////////////////////////////////////////////////////////
    bit                exp_tvalid;
    bit                exp_err_pulse;
    bit                exp_tready;
    logic [3*COLS-1:0] exp_col;
    logic [3*ROWS-1:0] exp_row;
    logic [XBARS-1:0]  exp_xb;
    int                gap_cnt;

    //////////////////////////////////////////////////////////////////////
    // Optional memory model (integration test only)
    // mem[x][row][col], OTP semantics: NOT/NOR can only clear a cell.
    //////////////////////////////////////////////////////////////////////
    bit                                   track_mem;
    logic [XBARS-1:0][ROWS-1:0][COLS-1:0] mem;

    //////////////////////////////////////////////////////////////////////
    // What the word processed in the last apply() did (for coverage)
    //////////////////////////////////////////////////////////////////////
    bit         last_acc, last_beat, last_rejected;
    logic [3:0] last_cause;
    logic [1:0] last_op;
    bit         last_col;
    bit         last_is_nop;

    // statistics since the last reset
    int n_acc, n_beats, n_rej, n_cfg, n_nop;

    function new(bit track_mem_i = 0);
      track_mem = track_mem_i;
      reset();
    endfunction

    //////////////////////////////////////////////////////////////////////
    // reset - state after rst_n (spec 5, last paragraph)
    //////////////////////////////////////////////////////////////////////
    function void reset();
      foreach (base[i]) base[i] = 0;
      m_start = 0;  m_end = 0;  c_start = 0;  c_end = 0;
      col = 0;  m_vld = 0;  c_vld = 0;
      err_cause = '0;  err_sticky = 0;
      exp_tvalid = 0;  exp_err_pulse = 0;  exp_tready = 1;
      exp_col = '0;  exp_row = '0;  exp_xb = '0;
      gap_cnt = 0;
      mem = '0;
      last_acc = 0;  last_beat = 0;  last_rejected = 0;  last_cause = '0;
      last_op = '0;  last_col = 0;  last_is_nop = 0;
      n_acc = 0;  n_beats = 0;  n_rej = 0;  n_cfg = 0;  n_nop = 0;
    endfunction

    //////////////////////////////////////////////////////////////////////
    // apply - advance the model by one clock cycle
    //   acc - a word was accepted on the rising edge that began this cycle
    //   w   - the accepted word (don't care when acc = 0)
    //   clr - err_clr was 1 on that edge
    //////////////////////////////////////////////////////////////////////
    function void apply(bit acc, logic [31:0] w, bit clr);
      logic [3:0] cause;
      bit         beat;
      cause         = '0;
      beat          = 0;
      last_acc      = acc;
      last_beat     = 0;
      last_rejected = 0;
      last_cause    = '0;
      last_is_nop   = 0;
      if (acc) begin
        n_acc++;
        if (w[0]) process_mem(w, beat, cause);
        else      process_cfg(w, cause);
      end
      if (cause != 4'b0) begin
        n_rej++;
        last_rejected = 1;
        last_cause    = cause;
      end
      last_beat     = beat;
      exp_tvalid    = beat;
      exp_err_pulse = (cause != 4'b0);
      // interpretation I1: clear first, then the new error wins
      if (clr) begin
        err_cause  = '0;
        err_sticky = 0;
      end
      err_cause = err_cause | cause;
      if (cause != 4'b0) err_sticky = 1;
      // spec 7: after a legal memory op, tready = 0 for BEAT_GAP-1 cycles
      if (beat)             gap_cnt = BEAT_GAP - 1;
      else if (gap_cnt > 0) gap_cnt--;
      exp_tready = (gap_cnt == 0);
    endfunction

    //////////////////////////////////////////////////////////////////////
    // op_code - operation-axis code for line i (spec 6.2)
    //   d, s1, s2 - absolute indices of dest / source 1 / source 2
    //////////////////////////////////////////////////////////////////////
    function logic [2:0] op_code(logic [1:0] op, int i, int d, int s1, int s2);
      int lo, hi;
      lo = imin(s1, s2);
      hi = imax(s1, s2);
      case (op)
        OP_NOT:  return (i == d) ? C_GND : ((i == s1) ? C_VG : C_FLOAT);
        OP_NOR:  return (i == d) ? C_GND : ((i == s1 || i == s2) ? C_VG : C_FLOAT);
        OP_SET:  return (i >= lo && i <= hi) ? C_VW1 : C_FLOAT;
        default: return (i >= lo && i <= hi) ? C_VW0 : C_FLOAT;
      endcase
    endfunction

    //////////////////////////////////////////////////////////////////////
    // mask_code - mask-axis code for line j (spec 6.3)
    //////////////////////////////////////////////////////////////////////
    function logic [2:0] mask_code(logic [1:0] op, int j);
      if (m_vld && j >= imin(m_start, m_end) && j <= imax(m_start, m_end))
        return (op == OP_NOT || op == OP_NOR) ? C_FLOAT : C_GND;
      return C_ISO;
    endfunction

    //////////////////////////////////////////////////////////////////////
    // process_mem - one memory op (spec 4.1, 6, 8)
    //   beat  - 1 if the op is legal and produces a beat
    //   cause - error bits (0 when legal)
    //////////////////////////////////////////////////////////////////////
    function void process_mem(logic [31:0] w, output bit beat, output logic [3:0] cause);
      logic [1:0] op;
      int         d, s1, s2, nop, clo, chi;
      beat  = 0;
      cause = '0;
      op    = w[2:1];
      // absolute indices are computed without wrapping (11-bit compare)
      d   = (w[3] ? base[3] : base[0]) + int'(w[11:4]);
      s1  = base[w[13:12]] + int'(w[21:14]);
      s2  = base[w[23:22]] + int'(w[31:24]);
      nop = col ? ROWS : COLS;
      last_op  = op;
      last_col = col;
      case (op)
        OP_NOT: begin
          if (d >= nop || s1 >= nop) cause[ERR_RANGE]  = 1'b1;
          if (d == s1)               cause[ERR_DSTSRC] = 1'b1;
        end
        OP_NOR: begin
          if (d >= nop || s1 >= nop || s2 >= nop) cause[ERR_RANGE]  = 1'b1;
          if (d == s1 || d == s2)                 cause[ERR_DSTSRC] = 1'b1;
        end
        default: begin // SET / RESET: dest field is ignored
          if (imax(s1, s2) >= nop) cause[ERR_RANGE] = 1'b1;
        end
      endcase
      if (cause != 4'b0) return;
      // spec 6.1: col = 0 -> ops on the column vector, mask on the row vector
      for (int i = 0; i < COLS; i++)
        exp_col[3*i +: 3] = col ? mask_code(op, i) : op_code(op, i, d, s1, s2);
      for (int r = 0; r < ROWS; r++)
        exp_row[3*r +: 3] = col ? op_code(op, r, d, s1, s2) : mask_code(op, r);
      // spec 6.4
      clo = imin(c_start, c_end);
      chi = imax(c_start, c_end);
      for (int x = 0; x < XBARS; x++)
        exp_xb[x] = c_vld && (x >= clo) && (x <= chi);
      if (track_mem) apply_mem(op, d, s1, s2);
      beat = 1;
      n_beats++;
    endfunction

    //////////////////////////////////////////////////////////////////////
    // process_cfg - one config op or NOP (spec 4.2, 8)
    // Only the listed fields are read, so unlisted bits are ignored.
    //////////////////////////////////////////////////////////////////////
    function void process_cfg(logic [31:0] w, output logic [3:0] cause);
      int a, b;
      cause = '0;
      a = int'(w[16:7]);
      b = int'(w[26:17]);
      case (w[4:1])
        CFG_SET_CMASK: begin
          if (imax(a, b) >= XBARS) cause[ERR_CMASK] = 1'b1;
          else begin
            c_start = a;  c_end = b;  c_vld = 1'b1;
          end
          n_cfg++;
        end
        CFG_SET_MASK: begin
          // the limit comes from the col field of the word itself
          if (imax(a, b) >= (w[6] ? COLS : ROWS)) cause[ERR_MASK] = 1'b1;
          else begin
            m_start = a;  m_end = b;  col = w[6];  m_vld = 1'b1;
          end
          n_cfg++;
        end
        CFG_SET_BASE: begin
          base[w[6:5]] = a;
          n_cfg++;
        end
        CFG_INC_BASE: begin
          for (int i = 0; i < 4; i++)
            if (w[5+i]) base[i] = (base[i] + 1) % 1024;
          n_cfg++;
        end
        default: begin
          n_nop++;
          last_is_nop = 1;
        end
      endcase
    endfunction

    //////////////////////////////////////////////////////////////////////
    // Memory model helpers.
    //   j = mask-axis line, i = operation-axis line
    //   col = 0: j is a row,    i is a column  -> mem[x][j][i]
    //   col = 1: j is a column, i is a row     -> mem[x][i][j]
    //////////////////////////////////////////////////////////////////////
    function bit get_cell(int x, int j, int i);
      return col ? mem[x][i][j] : mem[x][j][i];
    endfunction

    function void set_cell(int x, int j, int i, bit v);
      if (col) mem[x][i][j] = v;
      else     mem[x][j][i] = v;
    endfunction

    //////////////////////////////////////////////////////////////////////
    // apply_mem - effect of one legal beat on the array (OTP semantics)
    //   SET/RESET : write 1/0 on every active cell of the range
    //   NOT       : dest &= ~src1          (can only clear)
    //   NOR       : dest &= ~(src1 | src2) (can only clear)
    // Before any SET_MASK or SET_CMASK nothing changes (spec 5).
    //////////////////////////////////////////////////////////////////////
    function void apply_mem(logic [1:0] op, int d, int s1, int s2);
      int lo, hi;
      bit cur, a, b;
      if (!m_vld || !c_vld) return;
      lo = imin(s1, s2);
      hi = imax(s1, s2);
      for (int x = imin(c_start, c_end); x <= imax(c_start, c_end); x++)
        for (int j = imin(m_start, m_end); j <= imax(m_start, m_end); j++)
          case (op)
            OP_SET:   for (int i = lo; i <= hi; i++) set_cell(x, j, i, 1'b1);
            OP_RESET: for (int i = lo; i <= hi; i++) set_cell(x, j, i, 1'b0);
            OP_NOT: begin
              cur = get_cell(x, j, d);
              a   = get_cell(x, j, s1);
              set_cell(x, j, d, cur & ~a);
            end
            default: begin // NOR
              cur = get_cell(x, j, d);
              a   = get_cell(x, j, s1);
              b   = get_cell(x, j, s2);
              set_cell(x, j, d, cur & ~(a | b));
            end
          endcase
    endfunction

  endclass

  ////////////////////////////////////////////////////////////////////////
  // Random stimulus
  ////////////////////////////////////////////////////////////////////////

  // 1 with probability p percent
  function automatic int rnd_pct(input int p);
    return ($urandom_range(0, 99) < p);
  endfunction

  // Offset for a memory op field: mostly small, sometimes large
  function automatic int rnd_idx();
    int k;
    k = $urandom_range(0, 99);
    if (k < 85) return $urandom_range(0, 3);
    if (k < 97) return $urandom_range(0, 15);
    return $urandom_range(0, 255);
  endfunction

  // Index value for a base register or range: mostly legal for a size n,
  // sometimes on the boundary (n-2..n+1), rarely anything in 0..1023
  function automatic int rnd_val(input int n);
    int k;
    k = $urandom_range(0, 99);
    if (k < 80) return $urandom_range(0, n - 1);
    if (k < 95) return imax(0, n - 2 + int'($urandom_range(0, 3)));
    return $urandom_range(0, 1023);
  endfunction

  function automatic logic [31:0] rnd_mem_word();
    return enc_mem(2'($urandom_range(0, 3)), 1'($urandom_range(0, 1)), rnd_idx(),
                   2'($urandom_range(0, 3)), rnd_idx(),
                   2'($urandom_range(0, 3)), rnd_idx());
  endfunction

  // SET or RESET only (used to fill the array with data)
  function automatic logic [31:0] rnd_setreset_word();
    return enc_mem($urandom_range(0, 1) ? OP_SET : OP_RESET, 1'b0, 0,
                   2'($urandom_range(0, 3)), rnd_idx(),
                   2'($urandom_range(0, 3)), rnd_idx());
  endfunction

  // Type-0 word that is NOT one of the four config ops, with random
  // upper bits, or one of Arjun's real control words. All are NOPs.
  function automatic logic [31:0] rnd_nop_word();
    logic [31:0] w;
    int          ops [12] = '{0, 1, 2, 7, 8, 9, 10, 11, 12, 13, 14, 15};
    logic [31:0] arjun [6] = '{32'h00000010,   // ret
                               32'h0080001A,   // jump&load 128
                               32'h000001A0,   // ubr
                               32'h00900412,   // bnz
                               32'h00880018,   // jump 136
                               32'h00000000};  // all zero (ubr, no regs)
    if (rnd_pct(20)) return arjun[$urandom_range(0, 5)];
    w      = $urandom();
    w[0]   = 1'b0;
    w[4:1] = 4'(ops[$urandom_range(0, 11)]);
    return w;
  endfunction

  // Any word, weighted towards useful traffic
  function automatic logic [31:0] rnd_word(input int rows, input int cols, input int xbars);
    int k;
    bit c;
    k = $urandom_range(0, 99);
    if (k < 45) return rnd_mem_word();
    if (k < 57) return enc_set_base(2'($urandom_range(0, 3)), rnd_val(imax(rows, cols)));
    if (k < 63) return enc_inc_base(1'($urandom_range(0, 1)), 1'($urandom_range(0, 1)),
                                    1'($urandom_range(0, 1)), 1'($urandom_range(0, 1)));
    if (k < 75) begin
      c = 1'($urandom_range(0, 1));
      return enc_set_mask(rnd_val(c ? cols : rows), rnd_val(c ? cols : rows), c);
    end
    if (k < 83) return enc_set_cmask(rnd_val(xbars), rnd_val(xbars));
    return rnd_nop_word();
  endfunction

  ////////////////////////////////////////////////////////////////////////
  // Gate macros.
  // Each appends to queue q the words that compute one gate on the
  // current axis, SIMD over all active mask lines and crossbars.
  // d, a, b are absolute operation-axis lines. The caller sets TEMP
  // (SET_BASE TEMP t) once; temporaries live at TEMP+0..TEMP+3.
  // Every destination (including temporaries) is SET before the NOT/NOR,
  // because the array is OTP.
  ////////////////////////////////////////////////////////////////////////

  // d <- NOT a
  function automatic void g_not(ref logic [31:0] q [$], input int d, input int a);
    q.push_back(enc_set_base(SEL_DEST, d));
    q.push_back(enc_set_base(SEL_SRC1, a));
    q.push_back(enc_set(SEL_DEST, 0, SEL_DEST, 0));
    q.push_back(enc_not(1'b0, 0, SEL_SRC1, 0));
  endfunction

  // d <- NOR(a, b)
  function automatic void g_nor(ref logic [31:0] q [$], input int d, input int a, input int b);
    q.push_back(enc_set_base(SEL_DEST, d));
    q.push_back(enc_set_base(SEL_SRC1, a));
    q.push_back(enc_set_base(SEL_SRC2, b));
    q.push_back(enc_set(SEL_DEST, 0, SEL_DEST, 0));
    q.push_back(enc_nor(1'b0, 0, SEL_SRC1, 0, SEL_SRC2, 0));
  endfunction

  // d <- a OR b          uses TEMP+0
  function automatic void g_or(ref logic [31:0] q [$], input int d, input int a, input int b);
    q.push_back(enc_set_base(SEL_SRC1, a));
    q.push_back(enc_set_base(SEL_SRC2, b));
    q.push_back(enc_set_base(SEL_DEST, d));
    q.push_back(enc_set(SEL_TEMP, 0, SEL_TEMP, 0));
    q.push_back(enc_nor(1'b1, 0, SEL_SRC1, 0, SEL_SRC2, 0));   // T0 = NOR(a,b)
    q.push_back(enc_set(SEL_DEST, 0, SEL_DEST, 0));
    q.push_back(enc_not(1'b0, 0, SEL_TEMP, 0));                // d = NOT T0
  endfunction

  // d <- a AND b         uses TEMP+0, TEMP+1
  function automatic void g_and(ref logic [31:0] q [$], input int d, input int a, input int b);
    q.push_back(enc_set_base(SEL_SRC1, a));
    q.push_back(enc_set_base(SEL_SRC2, b));
    q.push_back(enc_set_base(SEL_DEST, d));
    q.push_back(enc_set(SEL_TEMP, 0, SEL_TEMP, 1));
    q.push_back(enc_not(1'b1, 0, SEL_SRC1, 0));                // T0 = NOT a
    q.push_back(enc_not(1'b1, 1, SEL_SRC2, 0));                // T1 = NOT b
    q.push_back(enc_set(SEL_DEST, 0, SEL_DEST, 0));
    q.push_back(enc_nor(1'b0, 0, SEL_TEMP, 0, SEL_TEMP, 1));   // d = NOR(T0,T1)
  endfunction

  // d <- a XOR b         uses TEMP+0..TEMP+3
  //   T0 = NOR(a,b)  T1 = NOR(a,T0)  T2 = NOR(b,T0)  T3 = NOR(T1,T2) = XNOR
  //   d  = NOT T3
  function automatic void g_xor(ref logic [31:0] q [$], input int d, input int a, input int b);
    q.push_back(enc_set_base(SEL_SRC1, a));
    q.push_back(enc_set_base(SEL_SRC2, b));
    q.push_back(enc_set_base(SEL_DEST, d));
    q.push_back(enc_set(SEL_TEMP, 0, SEL_TEMP, 3));
    q.push_back(enc_nor(1'b1, 0, SEL_SRC1, 0, SEL_SRC2, 0));
    q.push_back(enc_nor(1'b1, 1, SEL_SRC1, 0, SEL_TEMP, 0));
    q.push_back(enc_nor(1'b1, 2, SEL_SRC2, 0, SEL_TEMP, 0));
    q.push_back(enc_nor(1'b1, 3, SEL_TEMP, 1, SEL_TEMP, 2));
    q.push_back(enc_set(SEL_DEST, 0, SEL_DEST, 0));
    q.push_back(enc_not(1'b0, 0, SEL_TEMP, 3));
  endfunction

endpackage
