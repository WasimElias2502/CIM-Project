`timescale 1ns/1ps
////////////////////////////////////////////////////////////////////////
// tb_uop2vec_memarray.sv
// Integration testbench:  TB driver -> uop2vec_top -> memarray_top
//
// What it checks:
//   1. After EVERY beat commits inside memarray_top, the whole array
//      (mem_dbg) is compared with the reference memory model
//      (uop2vec_model with OTP semantics). Commit time is taken from
//      memarray_top's own s2 strobe (hierarchical reference u_mem.s2).
//   2. memarray_top starts exactly one pipeline run (u_mem.s1) for every
//      beat uop2vec_top sends - no beat dropped, none invented.
//      (If memarray_top is ever changed so that fire also requires its
//      own tready, beats sent BEAT_GAP = 2 apart would be dropped, and
//      this check reports it.)
//   3. memarray_top's err_sticky stays 0 (uop2vec never sends a beat the
//      array considers a protocol violation).
//   4. Independent golden results that do not use the model:
//        d0    - spec section 9 program, literal final memory
//        otp   - slide-6c NOR truth table, OTP "no write-1", NOT, RESET,
//                crossbar isolation, literal expected cells
//        logic - random inputs, NOT/NOR/OR/AND/XOR/full adder computed
//                in the array, compared with SV-computed booleans,
//                on both axes, with random partial masks
//   5. random - random microinstruction stream, per-beat memory checks.
//   6. BEAT_GAP = 1 only: hazard_demo (information, not a failure).
//
// Timing convention: inputs driven 1 ns after a rising edge, checks on
// the falling edge.
// Parameters: ROWS, COLS, XBARS, BEAT_GAP, N_RANDOM (-generic_top).
// Plusarg:   +TEST=<name|all>.  Random seed: xsim option -sv_seed <n>
////////////////////////////////////////////////////////////////////////
module tb_uop2vec_memarray;
  import uop2vec_tb_pkg::*;

  parameter int ROWS     = 16;
  parameter int COLS     = 16;
  parameter int XBARS    = 4;
  parameter int BEAT_GAP = 2;
  parameter int N_RANDOM = 3000;

  localparam int NMAX = (ROWS > COLS) ? ROWS : COLS;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  ////////////////////////////////////////////////////////////////////////
  // uop2vec_top
  ////////////////////////////////////////////////////////////////////////
  logic [31:0]      s_uop_tdata  = '0;
  logic             s_uop_tvalid = 1'b0;
  wire              s_uop_tready;
  wire [3*COLS-1:0] col_d;
  wire [3*ROWS-1:0] row_d;
  wire [XBARS-1:0]  xb_d;
  wire              col_v, row_v, xb_v;
  wire              u2v_err_sticky, u2v_err_pulse;
  wire [3:0]        u2v_err_cause;
  logic             err_clr = 1'b0;
  wire [9:0]        dbg_dest, dbg_src1, dbg_src2, dbg_temp;
  wire [9:0]        dbg_m_start, dbg_m_end, dbg_c_start, dbg_c_end;
  wire              dbg_col, dbg_m_vld, dbg_c_vld;

  uop2vec_top #(
    .ROWS     (ROWS),
    .COLS     (COLS),
    .XBARS    (XBARS),
    .BEAT_GAP (BEAT_GAP)
  ) u_u2v (
    .clk           (clk),
    .rst_n         (rst_n),
    .s_uop_tdata   (s_uop_tdata),
    .s_uop_tvalid  (s_uop_tvalid),
    .s_uop_tready  (s_uop_tready),
    .m_col_tdata   (col_d),
    .m_col_tvalid  (col_v),
    .m_col_tready  (1'b1),          // spec 3: ignored, tie to 1
    .m_row_tdata   (row_d),
    .m_row_tvalid  (row_v),
    .m_row_tready  (1'b1),
    .m_xbar_tdata  (xb_d),
    .m_xbar_tvalid (xb_v),
    .m_xbar_tready (1'b1),
    .err_sticky    (u2v_err_sticky),
    .err_cause     (u2v_err_cause),
    .err_pulse     (u2v_err_pulse),
    .err_clr       (err_clr)
`ifndef UOP2VEC_NO_DBG_PORTS
   ,.dbg_dest      (dbg_dest),
    .dbg_src1      (dbg_src1),
    .dbg_src2      (dbg_src2),
    .dbg_temp      (dbg_temp),
    .dbg_m_start   (dbg_m_start),
    .dbg_m_end     (dbg_m_end),
    .dbg_col       (dbg_col),
    .dbg_c_start   (dbg_c_start),
    .dbg_c_end     (dbg_c_end),
    .dbg_m_vld     (dbg_m_vld),
    .dbg_c_vld     (dbg_c_vld)
`endif
  );
  // (this testbench does not use the dbg values; with -d UOP2VEC_NO_DBG_PORTS
  //  they are simply left unconnected)

  ////////////////////////////////////////////////////////////////////////
  // memarray_top (same parameters)
  ////////////////////////////////////////////////////////////////////////
  wire                                   mem_col_rdy, mem_row_rdy, mem_xb_rdy;
  wire                                   mem_err;
  wire [XBARS-1:0][ROWS-1:0][COLS-1:0]   mem_state;

  memarray_top #(
    .ROWS  (ROWS),
    .COLS  (COLS),
    .XBARS (XBARS)
  ) u_mem (
    .clk           (clk),
    .rst_n         (rst_n),
    .s_col_tdata   (col_d),
    .s_col_tvalid  (col_v),
    .s_col_tready  (mem_col_rdy),   // observed only (uop2vec ignores it)
    .s_row_tdata   (row_d),
    .s_row_tvalid  (row_v),
    .s_row_tready  (mem_row_rdy),
    .s_xbar_tdata  (xb_d),
    .s_xbar_tvalid (xb_v),
    .s_xbar_tready (mem_xb_rdy),
    .err_sticky    (mem_err),
    .mem_dbg       (mem_state)
  );

  ////////////////////////////////////////////////////////////////////////
  // Model (with memory) and bookkeeping
  ////////////////////////////////////////////////////////////////////////
  uop2vec_model #(.ROWS(ROWS), .COLS(COLS), .XBARS(XBARS), .BEAT_GAP(BEAT_GAP)) mdl;

  string cur_test    = "init";
  int    n_fail      = 0;
  int    MAX_PRINT   = 40;
  bit    hazard_mode = 1'b0;   // BEAT_GAP = 1 demo: mismatches are counted, not failed
  int    n_hazard    = 0;

  function void fail(string msg);
    n_fail++;
    if (n_fail <= MAX_PRINT)
      $display("[%0t] FAIL [%s] %s", $time, cur_test, msg);
    if (n_fail == MAX_PRINT)
      $display("[%0t] ... more failures are counted but not printed", $time);
  endfunction

  ////////////////////////////////////////////////////////////////////////
  // report_mem_diff - print up to 8 differing cells between the array
  // and an expected image
  ////////////////////////////////////////////////////////////////////////
  function void report_mem_diff(input logic [XBARS-1:0][ROWS-1:0][COLS-1:0] exp_m, input string what);
    int shown;
    shown = 0;
    for (int x = 0; x < XBARS; x++)
      for (int r = 0; r < ROWS; r++)
        for (int c = 0; c < COLS; c++)
          if (mem_state[x][r][c] !== exp_m[x][r][c] && shown < 8) begin
            $display("        %s: xbar %0d row %0d col %0d : array=%b expected=%b",
                     what, x, r, c, mem_state[x][r][c], exp_m[x][r][c]);
            shown++;
          end
  endfunction

  ////////////////////////////////////////////////////////////////////////
  // Monitor (falling edge)
  ////////////////////////////////////////////////////////////////////////
  bit          pend_acc  = 1'b0;
  logic [31:0] pend_word = '0;
  bit          pend_clr  = 1'b0;
  bit          prev_beat = 1'b0;   // uop2vec sent a beat in the previous cycle
  bit          prev_s2   = 1'b0;   // memarray s2 was high in the previous cycle
  bit          mem_err_reported = 1'b0;
  logic [XBARS-1:0][ROWS-1:0][COLS-1:0] snapq [$];   // expected image after each beat
  logic [XBARS-1:0][ROWS-1:0][COLS-1:0] exp_img;
  int          n_beats_total   = 0;
  int          n_beat_mem_busy = 0;   // beats sent while memarray tready was 0

  always @(negedge clk) begin
    if (!rst_n) begin
      mdl.reset();
      pend_acc  = 1'b0;
      pend_clr  = 1'b0;
      prev_beat = 1'b0;
      prev_s2   = 1'b0;
      snapq.delete();
      mem_err_reported = 1'b0;
    end else begin
      mdl.apply(pend_acc, pend_word, pend_clr);

      // ---- uop2vec output against the model (full checks are in tb_uop2vec)
      if (col_v !== mdl.exp_tvalid || row_v !== mdl.exp_tvalid || xb_v !== mdl.exp_tvalid)
        fail($sformatf("uop2vec tvalid col/row/xbar = %b%b%b, model %b", col_v, row_v, xb_v, mdl.exp_tvalid));
      if (mdl.exp_tvalid && (col_d !== mdl.exp_col || row_d !== mdl.exp_row || xb_d !== mdl.exp_xb))
        fail($sformatf("uop2vec beat differs from the model: col %h/%h row %h/%h xbar %h/%h",
                       col_d, mdl.exp_col, row_d, mdl.exp_row, xb_d, mdl.exp_xb));

      // ---- memarray took every beat (its s1 follows one cycle after a beat)
      if (prev_beat  && u_mem.s1 !== 1'b1) fail("memarray_top did not take a beat (s1 stayed 0)");
      if (!prev_beat && u_mem.s1 === 1'b1) fail("memarray_top started a beat that uop2vec did not send");

      // ---- a beat this cycle: remember the expected image after it
      if (mdl.exp_tvalid) begin
        n_beats_total++;
        if (mem_col_rdy !== 1'b1) n_beat_mem_busy++;
        snapq.push_back(mdl.mem);
      end

      // ---- memarray committed on the edge that began this cycle
      if (prev_s2) begin
        if (snapq.size() == 0) fail("memarray_top committed but no beat was expected");
        else begin
          exp_img = snapq.pop_front();
          if (mem_state !== exp_img) begin
            if (hazard_mode) n_hazard++;
            else begin
              fail("array contents differ from the model after a beat commit");
              report_mem_diff(exp_img, "diff");
            end
          end
        end
      end

      if (mem_err !== 1'b0 && !mem_err_reported) begin
        mem_err_reported = 1'b1;
        if (!hazard_mode) fail("memarray_top err_sticky = 1 (it saw a protocol violation)");
      end

      prev_beat = mdl.exp_tvalid;
      prev_s2   = (u_mem.s2 === 1'b1);
      pend_acc  = (s_uop_tvalid === 1'b1) && (s_uop_tready === 1'b1);
      pend_word = s_uop_tdata;
      pend_clr  = (err_clr === 1'b1);
    end
  end

  ////////////////////////////////////////////////////////////////////////
  // Driver (same behaviour as in tb_uop2vec). Tasks start and end at
  // "rising edge + 1 ns".
  ////////////////////////////////////////////////////////////////////////
  logic [31:0] q [$];
  int          idle_pct = 0;
  int          drop_pct = 0;
  int          clr_pct  = 0;

  task automatic run_queue();
    bit          holding;
    bit          acc;
    logic [31:0] tmp;
    holding = 1'b0;
    while (q.size() > 0) begin
      err_clr = (clr_pct > 0) && rnd_pct(clr_pct);
      if (holding && !(drop_pct > 0 && rnd_pct(drop_pct))) begin
        s_uop_tvalid = 1'b1;
        s_uop_tdata  = q[0];
      end else begin
        if (holding && q.size() > 1 && rnd_pct(50)) begin
          tmp = q[0]; q[0] = q[1]; q[1] = tmp;
        end
        if (idle_pct > 0 && rnd_pct(idle_pct)) begin
          s_uop_tvalid = 1'b0;
          s_uop_tdata  = $urandom();
          holding      = 1'b0;
        end else begin
          s_uop_tvalid = 1'b1;
          s_uop_tdata  = q[0];
          holding      = 1'b1;
        end
      end
      @(negedge clk);
      acc = (s_uop_tvalid === 1'b1) && (s_uop_tready === 1'b1) && (rst_n === 1'b1);
      @(posedge clk);
      #1;
      if (acc) begin
        void'(q.pop_front());
        holding = 1'b0;
      end
    end
    s_uop_tvalid = 1'b0;
    err_clr      = 1'b0;
  endtask

  task automatic idle(input int n);
    s_uop_tvalid = 1'b0;
    repeat (n) @(posedge clk);
    #1;
  endtask

  // wait until uop2vec is quiet and every beat has committed in the array
  task automatic drain();
    s_uop_tvalid = 1'b0;
    err_clr      = 1'b0;
    idle(BEAT_GAP + 6);
    if (snapq.size() != 0) fail($sformatf("%0d beats never committed in the array", snapq.size()));
  endtask

  task automatic do_reset();
    @(posedge clk);
    #1;
    rst_n        = 1'b0;
    s_uop_tvalid = 1'b0;
    err_clr      = 1'b0;
    repeat (3) @(posedge clk);
    #1;
    rst_n = 1'b1;
  endtask

  int fail_at_start;
  task automatic start_test(input string name);
    cur_test = name;
    $display("[%0t] ---- test %s ----", $time, name);
    idle_pct = 0;  drop_pct = 0;  clr_pct = 0;
    q.delete();
    do_reset();
    fail_at_start = n_fail;
  endtask

  task automatic end_test();
    drain();
    if (!hazard_mode && mem_state !== mdl.mem) begin
      fail("final array contents differ from the model");
      report_mem_diff(mdl.mem, "final");
    end
    $display("[%0t] ---- test %s: %s  (words %0d, beats %0d, rejected %0d)",
             $time, cur_test, okfail(n_fail == fail_at_start),
             mdl.n_acc, mdl.n_beats, mdl.n_rej);
  endtask

  ////////////////////////////////////////////////////////////////////////
  // Access helpers for the independent checks.
  //   axis = 0: j = row (mask line),    i = column (op line)
  //   axis = 1: j = column (mask line), i = row (op line)
  ////////////////////////////////////////////////////////////////////////
  function automatic bit arr_bit(input bit axis, input int x, input int j, input int i);
    return axis ? mem_state[x][i][j] : mem_state[x][j][i];
  endfunction

  // check one cell against a literal value
  function void expect_cell(input int x, input int r, input int c, input bit v, input string what);
    if (mem_state[x][r][c] !== v)
      fail($sformatf("%s: xbar %0d row %0d col %0d = %b, expected %b", what, x, r, c, mem_state[x][r][c], v));
  endfunction

  ////////////////////////////////////////////////////////////////////////
  // TEST d0 - spec section 9 program through the array.
  // Expected final array (derived by hand from the spec table):
  //   SET col 2 on rows 0-3, crossbars 0-1   -> those 8 cells = 1
  //   NOT col5 -> col2 : col5 = 0            -> col 2 stays 1
  //   NOT col6 -> col3 : col3 never SET      -> stays 0 (OTP)
  //   rows mode NOT row6 -> row3, all cols   -> row 6 = 0, row 3 unchanged
  //   rows 12 and 13 are rejected            -> no effect
  // So: cell = 1 exactly for xbar 0-1, row 0-3, col 2. Everything else 0.
  ////////////////////////////////////////////////////////////////////////
  task automatic test_d0();
    if (!(ROWS == 8 && COLS == 8 && XBARS >= 2)) begin
      $display("[%0t] ---- test d0 skipped (needs ROWS = COLS = 8, XBARS >= 2)", $time);
      return;
    end
    start_test("d0");
    q.push_back(32'h00020006);  q.push_back(32'h00060008);  q.push_back(32'h0000010A);
    q.push_back(32'h000002AA);  q.push_back(32'h00000005);  q.push_back(32'h00001001);
    q.push_back(32'h0000006C);  q.push_back(32'h00001001);  q.push_back(32'h000E0048);
    q.push_back(32'h00001001);  q.push_back(32'h0000038A);  q.push_back(32'h00001011);
    q.push_back(32'h00000001);
    run_queue();
    drain();
    for (int x = 0; x < XBARS; x++)
      for (int r = 0; r < ROWS; r++)
        for (int c = 0; c < COLS; c++)
          expect_cell(x, r, c, (x < 2 && r < 4 && c == 2), "d0");
    if (u2v_err_cause !== 4'b0011) fail($sformatf("d0: uop2vec err_cause = %b, spec says 0011", u2v_err_cause));
    end_test();
  endtask

  ////////////////////////////////////////////////////////////////////////
  // TEST otp - MAGIC/OTP behaviour with literal expected cells (col mode)
  //   lines: A = col 1, B = col 2
  //   col 3 : SET, then NOR(A,B)       -> slide 6c table
  //   col 4 : NOR(A,B) WITHOUT SET     -> stays 0 (NOR cannot write 1)
  //   col 5 : SET, NOT A, then RESET rows 0-1
  //   col 6 : SET on crossbar 0 only   -> other crossbars untouched
  //   rows 0-3: (A,B) = (1,0) (0,0) (0,1) (1,1)
  ////////////////////////////////////////////////////////////////////////
  task automatic test_otp();
    bit a_v [4] = '{1, 0, 0, 1};
    bit b_v [4] = '{0, 0, 1, 1};
    if (COLS < 7 || ROWS < 5) begin
      $display("[%0t] ---- test otp skipped (needs COLS >= 7, ROWS >= 5)", $time);
      return;
    end
    start_test("otp");
    q.push_back(enc_set_cmask(0, XBARS - 1));
    for (int r = 0; r < 4; r++) begin
      q.push_back(enc_set_mask(r, r, 1'b0));
      if (a_v[r]) begin q.push_back(enc_set_base(SEL_DEST, 1)); q.push_back(enc_set(SEL_DEST, 0, SEL_DEST, 0)); end
      if (b_v[r]) begin q.push_back(enc_set_base(SEL_DEST, 2)); q.push_back(enc_set(SEL_DEST, 0, SEL_DEST, 0)); end
    end
    q.push_back(enc_set_mask(0, 3, 1'b0));
    q.push_back(enc_set_base(SEL_SRC1, 1));
    q.push_back(enc_set_base(SEL_SRC2, 2));
    q.push_back(enc_set_base(SEL_DEST, 3));                           // col 3
    q.push_back(enc_set(SEL_DEST, 0, SEL_DEST, 0));
    q.push_back(enc_nor(1'b0, 0, SEL_SRC1, 0, SEL_SRC2, 0));
    q.push_back(enc_set_base(SEL_DEST, 4));                           // col 4, no SET
    q.push_back(enc_nor(1'b0, 0, SEL_SRC1, 0, SEL_SRC2, 0));
    q.push_back(enc_set_base(SEL_DEST, 5));                           // col 5
    q.push_back(enc_set(SEL_DEST, 0, SEL_DEST, 0));
    q.push_back(enc_not(1'b0, 0, SEL_SRC1, 0));
    q.push_back(enc_set_mask(1, 0, 1'b0));                            // rows 0-1 (reversed)
    q.push_back(enc_reset(SEL_DEST, 0, SEL_DEST, 0));
    q.push_back(enc_set_mask(0, 3, 1'b0));                            // col 6 on crossbar 0 only
    q.push_back(enc_set_cmask(0, 0));
    q.push_back(enc_set_base(SEL_DEST, 6));
    q.push_back(enc_set(SEL_DEST, 0, SEL_DEST, 0));
    run_queue();
    drain();
    for (int x = 0; x < XBARS; x++) begin
      for (int r = 0; r < 4; r++) begin
        expect_cell(x, r, 1, a_v[r], "input A");
        expect_cell(x, r, 2, b_v[r], "input B");
        expect_cell(x, r, 3, !(a_v[r] | b_v[r]), "SET + NOR (slide 6c)");
        expect_cell(x, r, 4, 1'b0, "NOR without SET must stay 0 (OTP)");
        expect_cell(x, r, 5, (r >= 2) ? !a_v[r] : 1'b0, "SET + NOT, then RESET rows 0-1");
        expect_cell(x, r, 6, (x == 0), "SET on crossbar 0 only");
      end
      for (int r = 4; r < ROWS; r++)
        for (int c = 0; c < COLS; c++)
          expect_cell(x, r, c, 1'b0, "row outside every mask");
    end
    end_test();
  endtask

  ////////////////////////////////////////////////////////////////////////
  // TEST logic - gates computed in the array, checked against booleans
  // computed here from the random inputs (does not use the model).
  //   op-axis lines: A=0 B=1 C=2 | NOT A=3 NOR=4 OR=5 AND=6 XOR=7
  //                  SUM=8 COUT=9 | X1=10 (A^B) CX=11 (C&X1) | TEMP=12..15
  //   inputs written for every crossbar and mask line, then the gates run
  //   once on a random sub-range of crossbars and mask lines (SIMD); cells
  //   outside that range must stay 0.
  //   axis - 0: gates on columns (mask = rows), 1: gates on rows
  ////////////////////////////////////////////////////////////////////////
  bit inp [XBARS][NMAX][3];

  task automatic test_logic(input bit axis);
    int  nop, nm, xlo, xhi, jlo, jhi;
    bit  a, b, c, x1, in_rng;
    bit  expv [12];
    nop = axis ? ROWS : COLS;
    nm  = axis ? COLS : ROWS;
    if (nop < 16) begin
      $display("[%0t] ---- test logic axis=%0d skipped (needs %s >= 16)", $time, axis, axis ? "ROWS" : "COLS");
      return;
    end
    start_test($sformatf("logic_axis%0d", axis));
    // ---- write random inputs A, B, C: one mask line and one crossbar at a time
    for (int x = 0; x < XBARS; x++)
      for (int j = 0; j < nm; j++) begin
        q.push_back(enc_set_cmask(x, x));
        q.push_back(enc_set_mask(j, j, axis));
        for (int k = 0; k < 3; k++) begin
          inp[x][j][k] = 1'($urandom_range(0, 1));
          q.push_back(enc_set_base(SEL_DEST, k));
          if (inp[x][j][k]) q.push_back(enc_set  (SEL_DEST, 0, SEL_DEST, 0));
          else              q.push_back(enc_reset(SEL_DEST, 0, SEL_DEST, 0));
        end
      end
    // ---- run the gates on a random region, written in random order
    xlo = $urandom_range(0, XBARS - 1);  xhi = $urandom_range(xlo, XBARS - 1);
    jlo = $urandom_range(0, nm - 1);     jhi = $urandom_range(jlo, nm - 1);
    q.push_back($urandom_range(0, 1) ? enc_set_cmask(xlo, xhi) : enc_set_cmask(xhi, xlo));
    q.push_back($urandom_range(0, 1) ? enc_set_mask(jlo, jhi, axis) : enc_set_mask(jhi, jlo, axis));
    q.push_back(enc_set_base(SEL_TEMP, 12));
    g_not(q, 3, 0);
    g_nor(q, 4, 0, 1);
    g_or (q, 5, 0, 1);
    g_and(q, 6, 0, 1);
    g_xor(q, 7, 0, 1);
    g_xor(q, 10, 0, 1);      // X1 = A ^ B
    g_xor(q, 8, 10, 2);      // SUM = X1 ^ C
    g_and(q, 11, 2, 10);     // CX = C & X1
    g_or (q, 9, 6, 11);      // COUT = (A & B) | CX
    idle_pct = 10;
    run_queue();
    drain();
    // ---- independent check
    for (int x = 0; x < XBARS; x++)
      for (int j = 0; j < nm; j++) begin
        a = inp[x][j][0];  b = inp[x][j][1];  c = inp[x][j][2];
        x1 = a ^ b;
        in_rng = (x >= xlo && x <= xhi && j >= jlo && j <= jhi);
        expv[0] = a;  expv[1] = b;  expv[2] = c;
        expv[3]  = in_rng & !a;
        expv[4]  = in_rng & !(a | b);
        expv[5]  = in_rng & (a | b);
        expv[6]  = in_rng & (a & b);
        expv[7]  = in_rng & x1;
        expv[8]  = in_rng & (x1 ^ c);
        expv[9]  = in_rng & ((a & b) | (c & x1));
        expv[10] = in_rng & x1;
        expv[11] = in_rng & (c & x1);
        for (int i = 0; i < 12; i++)
          if (arr_bit(axis, x, j, i) !== expv[i])
            fail($sformatf("logic axis=%0d xbar %0d line %0d, op line %0d = %b, expected %b (A=%b B=%b C=%b, in region=%b)",
                           axis, x, j, i, arr_bit(axis, x, j, i), expv[i], a, b, c, in_rng));
      end
    end_test();
  endtask

  ////////////////////////////////////////////////////////////////////////
  // TEST random - fill the array with random SET/RESET, then a random
  // microinstruction stream (legal and illegal) with idle cycles, tvalid
  // drops and err_clr pulses. Every beat is checked in the array.
  ////////////////////////////////////////////////////////////////////////
  task automatic test_random();
    start_test("random");
    q.push_back(enc_set_cmask(0, XBARS - 1));
    for (int i = 0; i < 300; i++) begin
      if (rnd_pct(15)) q.push_back(enc_set_base(2'($urandom_range(0, 3)), $urandom_range(0, NMAX - 1)));
      if (rnd_pct(10)) begin
        int ax;
        ax = $urandom_range(0, 1);
        q.push_back(enc_set_mask($urandom_range(0, (ax ? COLS : ROWS) - 1),
                                 $urandom_range(0, (ax ? COLS : ROWS) - 1), 1'(ax)));
      end
      q.push_back(rnd_setreset_word());
    end
    for (int i = 0; i < N_RANDOM; i++) q.push_back(rnd_word(ROWS, COLS, XBARS));
    idle_pct = 15;
    drop_pct = 10;
    clr_pct  = 2;
    run_queue();
    end_test();
  endtask

  ////////////////////////////////////////////////////////////////////////
  // TEST hazard_demo - only when BEAT_GAP = 1. Spec 7 says 1 cycle is
  // too close for memarray_top. Dependent beats are sent back to back and
  // the number of wrong commits is reported. Not counted as a failure.
  ////////////////////////////////////////////////////////////////////////
  task automatic test_hazard_demo();
    if (COLS < 4) return;
    start_test("hazard_demo");
    hazard_mode = 1'b1;
    q.push_back(enc_set_cmask(0, XBARS - 1));
    q.push_back(enc_set_mask(0, ROWS - 1, 1'b0));
    q.push_back(enc_set_base(SEL_SRC1, 1));
    q.push_back(enc_set_base(SEL_DEST, 2));
    for (int i = 0; i < 20; i++) begin
      q.push_back(enc_set(SEL_SRC1, 0, SEL_SRC1, 0));      // A = 1
      q.push_back(enc_set(SEL_DEST, 0, SEL_DEST, 0));      // SET dest
      q.push_back(enc_not(1'b0, 0, SEL_SRC1, 0));          // dest = NOT A -> 0
      q.push_back(enc_reset(SEL_SRC1, 0, SEL_SRC1, 0));    // A = 0
      q.push_back(enc_set(SEL_DEST, 0, SEL_DEST, 0));      // SET dest
      q.push_back(enc_not(1'b0, 0, SEL_SRC1, 0));          // dest = NOT A -> 1
    end
    run_queue();
    end_test();
    if (n_hazard > 0)
      $display("[%0t] INFO hazard_demo: %0d beat commits differed from the model with BEAT_GAP = 1 (hazard visible, as the spec predicts)",
               $time, n_hazard);
    else
      $display("[%0t] INFO hazard_demo: no wrong commit seen with BEAT_GAP = 1 - check the spec claim", $time);
  endtask

  function automatic bit want(input string tsel, input string name);
    return (tsel == "all") || (tsel == name);
  endfunction

  ////////////////////////////////////////////////////////////////////////
  // Main
  ////////////////////////////////////////////////////////////////////////
  initial begin
    string tsel;
    mdl = new(1'b1);   // with memory model
    if (!$value$plusargs("TEST=%s", tsel)) tsel = "all";
    // Random seed: xsim does not support $urandom(seed); set it with the
    // xsim option  -sv_seed <n>  (run_tb.bat / create_sim_project.tcl do).
    $display("==== tb_uop2vec_memarray  ROWS=%0d COLS=%0d XBARS=%0d BEAT_GAP=%0d  TEST=%s ====",
             ROWS, COLS, XBARS, BEAT_GAP, tsel);
    if (check_encoders() != 0) fail("testbench encoders do not match the spec examples");

    if (BEAT_GAP == 1) begin
      if (want(tsel, "hazard_demo")) test_hazard_demo();
    end else begin
      if (want(tsel, "d0"))     test_d0();
      if (want(tsel, "otp"))    test_otp();
      if (want(tsel, "logic"))  begin test_logic(1'b0); test_logic(1'b1); end
      if (want(tsel, "random")) test_random();
    end

    $display("---- summary: %0d beats in total, %0d of them sent while memarray_top tready = 0 (allowed by the spec, tready is ignored)",
             n_beats_total, n_beat_mem_busy);
    if (n_fail == 0) begin
      $display("*** TEST PASSED ***");
      $finish;
    end else begin
      $display("*** TEST FAILED: %0d check failures ***", n_fail);
      $fatal(1, "tb_uop2vec_memarray failed");
    end
  end

endmodule
