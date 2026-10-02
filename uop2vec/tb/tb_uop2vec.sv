`timescale 1ns/1ps
////////////////////////////////////////////////////////////////////////
// tb_uop2vec.sv
// Standalone testbench for uop2vec_top (no memory array).
//
// How it checks (spec = "uop2vec - Design & Verification Spec", 25 Sep 2026):
//   1. Reference model (uop2vec_tb_pkg::uop2vec_model) runs in lock-step.
//      EVERY cycle, EVERY output is compared with it: s_uop_tready,
//      m_*_tvalid, m_*_tdata (also while tvalid = 0, which checks the
//      "hold last beat" rule), err_pulse, err_sticky, err_cause, dbg_*.
//   2. Model-independent protocol checks (spec 7 "Rules the testbench
//      must check") and beat invariants (spec 6.5).
//   3. Literal golden values copied from the spec: the encoding table
//      (4.3), the waveform (7) and directed test D0 (9).
//
// Timing convention: inputs are driven 1 ns after a rising edge; all
// checks happen on the falling edge, where DUT outputs are stable.
//
// Parameters can be overridden at elaboration, e.g.
//   xelab tb_uop2vec -generic_top "ROWS=8" -generic_top "COLS=16" ...
// Plusarg: +TEST=<name|all>.  Random seed: xsim option -sv_seed <n>
////////////////////////////////////////////////////////////////////////
module tb_uop2vec;
  import uop2vec_tb_pkg::*;

  parameter int ROWS     = 8;
  parameter int COLS     = 8;
  parameter int XBARS    = 8;
  parameter int BEAT_GAP = 2;
  parameter int N_RANDOM = 4000;

  ////////////////////////////////////////////////////////////////////////
  // Clock and reset. 100 MHz.
  ////////////////////////////////////////////////////////////////////////
  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  ////////////////////////////////////////////////////////////////////////
  // DUT connections (port list = spec section 3)
  ////////////////////////////////////////////////////////////////////////
  logic [31:0]      s_uop_tdata  = '0;
  logic             s_uop_tvalid = 1'b0;
  wire              s_uop_tready;
  wire [3*COLS-1:0] m_col_tdata;
  wire              m_col_tvalid;
  wire [3*ROWS-1:0] m_row_tdata;
  wire              m_row_tvalid;
  wire [XBARS-1:0]  m_xbar_tdata;
  wire              m_xbar_tvalid;
  wire              err_sticky;
  wire [3:0]        err_cause;
  wire              err_pulse;
  logic             err_clr = 1'b0;
  wire [9:0]        dbg_dest, dbg_src1, dbg_src2, dbg_temp;
  wire [9:0]        dbg_m_start, dbg_m_end, dbg_c_start, dbg_c_end;
  wire              dbg_col, dbg_m_vld, dbg_c_vld;

  uop2vec_top #(
    .ROWS     (ROWS),
    .COLS     (COLS),
    .XBARS    (XBARS),
    .BEAT_GAP (BEAT_GAP)
  ) dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .s_uop_tdata   (s_uop_tdata),
    .s_uop_tvalid  (s_uop_tvalid),
    .s_uop_tready  (s_uop_tready),
    .m_col_tdata   (m_col_tdata),
    .m_col_tvalid  (m_col_tvalid),
    .m_col_tready  (1'b1),          // spec 3: ignored, tie to 1
    .m_row_tdata   (m_row_tdata),
    .m_row_tvalid  (m_row_tvalid),
    .m_row_tready  (1'b1),
    .m_xbar_tdata  (m_xbar_tdata),
    .m_xbar_tvalid (m_xbar_tvalid),
    .m_xbar_tready (1'b1),
    .err_sticky    (err_sticky),
    .err_cause     (err_cause),
    .err_pulse     (err_pulse),
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

`ifdef UOP2VEC_NO_DBG_PORTS
  ////////////////////////////////////////////////////////////////////////
  // Fallback for an RTL WITHOUT the dbg_* ports of spec section 3:
  // compile with -d UOP2VEC_NO_DBG_PORTS and the same registers are read
  // inside the design instead.
  ////////////////////////////////////////////////////////////////////////
  assign dbg_dest    = dut.reg_base_dest;
  assign dbg_src1    = dut.reg_base_src1;
  assign dbg_src2    = dut.reg_base_src2;
  assign dbg_temp    = dut.reg_base_temp;
  assign dbg_m_start = dut.reg_m_start;
  assign dbg_m_end   = dut.reg_m_end;
  assign dbg_col     = dut.reg_col;
  assign dbg_c_start = dut.reg_c_start;
  assign dbg_c_end   = dut.reg_c_end;
  assign dbg_m_vld   = dut.reg_m_vld;
  assign dbg_c_vld   = dut.reg_c_vld;
`endif

  ////////////////////////////////////////////////////////////////////////
  // Reference model and result bookkeeping
  ////////////////////////////////////////////////////////////////////////
  uop2vec_model #(.ROWS(ROWS), .COLS(COLS), .XBARS(XBARS), .BEAT_GAP(BEAT_GAP)) mdl;

  string cur_test  = "init";
  int    n_fail    = 0;
  int    MAX_PRINT = 40;

  ////////////////////////////////////////////////////////////////////////
  // fail - count and print one check failure
  //   msg - what was wrong
  ////////////////////////////////////////////////////////////////////////
  function void fail(string msg);
    n_fail++;
    if (n_fail <= MAX_PRINT)
      $display("[%0t] FAIL [%s] %s", $time, cur_test, msg);
    if (n_fail == MAX_PRINT)
      $display("[%0t] ... more failures are counted but not printed", $time);
  endfunction

  ////////////////////////////////////////////////////////////////////////
  // Every beat seen on the outputs, in order (used by literal checks)
  ////////////////////////////////////////////////////////////////////////
  typedef struct {
    logic [3*COLS-1:0] c;
    logic [3*ROWS-1:0] r;
    logic [XBARS-1:0]  x;
  } beat_t;
  beat_t beat_log [$];

  ////////////////////////////////////////////////////////////////////////
  // Coverage counters (printed at the end, holes reported as warnings)
  ////////////////////////////////////////////////////////////////////////
  int cov_beat  [4][2];     // [op][col]
  int cov_cause [4];
  int cov_multi_cause = 0;  // one word with two cause bits
  int cov_clr_hit     = 0;  // err_clr on the same edge as a rejected word
  int cov_nop         = 0;
  int cov_stall       = 0;  // tvalid = 1 while tready = 0
  int cov_drop        = 0;  // source dropped tvalid before acceptance

  ////////////////////////////////////////////////////////////////////////
  // check_axes - spec 6.5 for one beat, once the axes are known
  //   o  - code histogram of the operation-axis vector
  //   m  - code histogram of the mask-axis vector
  //   oname - name of the op-axis vector ("col"/"row") for messages
  // Returns "" when the beat is fine, otherwise a description.
  ////////////////////////////////////////////////////////////////////////
  function automatic string check_axes(input int o [8], input int m [8], input string oname);
    if (o[3] || o[6] || o[7])
      return $sformatf("op axis (%s) contains 011/110/111", oname);
    if (m[1] || m[2] || m[3] || m[4] || m[6])
      return "mask axis contains a code other than 000/101/111";
    if (o[2] > 0) begin
      if (o[1] || o[4] || o[5]) return "SET beat: op axis has codes other than 010/000";
      if (m[0] > 0)             return "SET beat: active mask lines must be 101, found 000";
    end else if (o[1] > 0) begin
      if (o[2] || o[4] || o[5]) return "RESET beat: op axis has codes other than 001/000";
      if (m[0] > 0)             return "RESET beat: active mask lines must be 101, found 000";
    end else begin
      if (o[5] != 1)            return $sformatf("NOT/NOR beat: %0d lines with 101 (must be 1)", o[5]);
      if (o[4] < 1 || o[4] > 2) return $sformatf("NOT/NOR beat: %0d lines with 100 (must be 1 or 2)", o[4]);
      if (m[5] > 0)             return "NOT/NOR beat: active mask lines must be 000, found 101";
    end
    return "";
  endfunction

  ////////////////////////////////////////////////////////////////////////
  // check_invariants - spec 6.5 on raw vectors, without using the model.
  // The operation axis is the vector that holds 100, 010 or 001.
  ////////////////////////////////////////////////////////////////////////
  function automatic string check_invariants(input logic [3*COLS-1:0] cv,
                                             input logic [3*ROWS-1:0] rv);
    int nc [8];
    int nr [8];
    bit col_is_op, row_is_op;
    if ((^cv) === 1'bx || (^rv) === 1'bx) return "X or Z in a vector";
    foreach (nc[i]) begin nc[i] = 0; nr[i] = 0; end
    for (int i = 0; i < COLS; i++) nc[cv[3*i +: 3]]++;
    for (int i = 0; i < ROWS; i++) nr[rv[3*i +: 3]]++;
    col_is_op = (nc[1] + nc[2] + nc[4]) > 0;
    row_is_op = (nr[1] + nr[2] + nr[4]) > 0;
    if (col_is_op == row_is_op)
      return "cannot tell the operation axis: both or neither vector carries 100/010/001";
    if (col_is_op) return check_axes(nc, nr, "col");
    return check_axes(nr, nc, "row");
  endfunction

  ////////////////////////////////////////////////////////////////////////
  // Monitor state
  ////////////////////////////////////////////////////////////////////////
  bit                pend_acc      = 1'b0;   // word accepted on the coming edge
  logic [31:0]       pend_word     = '0;
  bit                pend_clr      = 1'b0;
  logic [31:0]       applied_word  = '0;     // for messages
  int                cyc           = 0;
  int                last_beat_cyc = -1000;
  bit                prev_tv       = 1'b0;
  logic [3*COLS-1:0] prev_c        = '0;
  logic [3*ROWS-1:0] prev_r        = '0;
  logic [XBARS-1:0]  prev_x        = '0;

  function string ctx();
    return mdl.last_acc ? $sformatf("(after word %08h)", applied_word)
                        : "(no word accepted on the last edge)";
  endfunction

  ////////////////////////////////////////////////////////////////////////
  // check_reset_values - spec 5: outputs while / after reset
  ////////////////////////////////////////////////////////////////////////
  function void check_reset_values();
    if (m_col_tvalid !== 1'b0 || m_row_tvalid !== 1'b0 || m_xbar_tvalid !== 1'b0)
      fail("in reset: tvalid is not 0");
    if (m_col_tdata !== '0 || m_row_tdata !== '0 || m_xbar_tdata !== '0)
      fail("in reset: tdata is not 0");
    if (s_uop_tready !== 1'b1)
      fail("in reset: s_uop_tready is not 1");
    if (err_sticky !== 1'b0 || err_cause !== 4'b0 || err_pulse !== 1'b0)
      fail("in reset: err_* is not 0");
    if (dbg_dest !== '0 || dbg_src1 !== '0 || dbg_src2 !== '0 || dbg_temp !== '0 ||
        dbg_m_start !== '0 || dbg_m_end !== '0 || dbg_c_start !== '0 || dbg_c_end !== '0 ||
        dbg_col !== 1'b0 || dbg_m_vld !== 1'b0 || dbg_c_vld !== 1'b0)
      fail("in reset: a dbg_* output is not 0");
  endfunction

  ////////////////////////////////////////////////////////////////////////
  // compare_to_model - every output against the model, every cycle
  ////////////////////////////////////////////////////////////////////////
  function void compare_to_model();
    if (s_uop_tready !== mdl.exp_tready)
      fail($sformatf("s_uop_tready = %b, expected %b %s", s_uop_tready, mdl.exp_tready, ctx()));
    if (m_col_tvalid !== mdl.exp_tvalid)
      fail($sformatf("m_col_tvalid = %b, expected %b %s", m_col_tvalid, mdl.exp_tvalid, ctx()));
    if (m_col_tdata !== mdl.exp_col)
      fail($sformatf("m_col_tdata = %h, expected %h %s", m_col_tdata, mdl.exp_col, ctx()));
    if (m_row_tdata !== mdl.exp_row)
      fail($sformatf("m_row_tdata = %h, expected %h %s", m_row_tdata, mdl.exp_row, ctx()));
    if (m_xbar_tdata !== mdl.exp_xb)
      fail($sformatf("m_xbar_tdata = %h, expected %h %s", m_xbar_tdata, mdl.exp_xb, ctx()));
    if (err_pulse !== mdl.exp_err_pulse)
      fail($sformatf("err_pulse = %b, expected %b %s", err_pulse, mdl.exp_err_pulse, ctx()));
    if (err_sticky !== mdl.err_sticky)
      fail($sformatf("err_sticky = %b, expected %b %s", err_sticky, mdl.err_sticky, ctx()));
    if (err_cause !== mdl.err_cause)
      fail($sformatf("err_cause = %b, expected %b %s", err_cause, mdl.err_cause, ctx()));
    if (dbg_dest    !== 10'(mdl.base[0])) fail($sformatf("dbg_dest = %0d, expected %0d %s",    dbg_dest,    mdl.base[0], ctx()));
    if (dbg_src1    !== 10'(mdl.base[1])) fail($sformatf("dbg_src1 = %0d, expected %0d %s",    dbg_src1,    mdl.base[1], ctx()));
    if (dbg_src2    !== 10'(mdl.base[2])) fail($sformatf("dbg_src2 = %0d, expected %0d %s",    dbg_src2,    mdl.base[2], ctx()));
    if (dbg_temp    !== 10'(mdl.base[3])) fail($sformatf("dbg_temp = %0d, expected %0d %s",    dbg_temp,    mdl.base[3], ctx()));
    if (dbg_m_start !== 10'(mdl.m_start)) fail($sformatf("dbg_m_start = %0d, expected %0d %s", dbg_m_start, mdl.m_start, ctx()));
    if (dbg_m_end   !== 10'(mdl.m_end))   fail($sformatf("dbg_m_end = %0d, expected %0d %s",   dbg_m_end,   mdl.m_end,   ctx()));
    if (dbg_c_start !== 10'(mdl.c_start)) fail($sformatf("dbg_c_start = %0d, expected %0d %s", dbg_c_start, mdl.c_start, ctx()));
    if (dbg_c_end   !== 10'(mdl.c_end))   fail($sformatf("dbg_c_end = %0d, expected %0d %s",   dbg_c_end,   mdl.c_end,   ctx()));
    if (dbg_col     !== mdl.col)          fail($sformatf("dbg_col = %b, expected %b %s",       dbg_col,     mdl.col,     ctx()));
    if (dbg_m_vld   !== mdl.m_vld)        fail($sformatf("dbg_m_vld = %b, expected %b %s",     dbg_m_vld,   mdl.m_vld,   ctx()));
    if (dbg_c_vld   !== mdl.c_vld)        fail($sformatf("dbg_c_vld = %b, expected %b %s",     dbg_c_vld,   mdl.c_vld,   ctx()));
  endfunction

  ////////////////////////////////////////////////////////////////////////
  // protocol_checks - spec 7 rules, independent of the model
  ////////////////////////////////////////////////////////////////////////
  function void protocol_checks();
    string s;
    beat_t b;
    if (!(m_col_tvalid === m_row_tvalid && m_row_tvalid === m_xbar_tvalid))
      fail($sformatf("tvalid differ: col=%b row=%b xbar=%b", m_col_tvalid, m_row_tvalid, m_xbar_tvalid));
    if (m_col_tvalid === 1'b1) begin
      if (BEAT_GAP >= 2 && prev_tv)
        fail("tvalid is high in two cycles in a row");
      if (cyc - last_beat_cyc < BEAT_GAP)
        fail($sformatf("two beats %0d cycles apart, BEAT_GAP = %0d", cyc - last_beat_cyc, BEAT_GAP));
      last_beat_cyc = cyc;
      s = check_invariants(m_col_tdata, m_row_tdata);
      if (s != "") fail({"beat invariant (spec 6.5): ", s});
      b.c = m_col_tdata;
      b.r = m_row_tdata;
      b.x = m_xbar_tdata;
      beat_log.push_back(b);
    end else begin
      if (m_col_tdata !== prev_c || m_row_tdata !== prev_r || m_xbar_tdata !== prev_x)
        fail("m_*_tdata changed in a cycle with tvalid = 0");
    end
    prev_tv = (m_col_tvalid === 1'b1);
    prev_c  = m_col_tdata;
    prev_r  = m_row_tdata;
    prev_x  = m_xbar_tdata;
  endfunction

  function void collect_coverage();
    if (mdl.last_beat) cov_beat[mdl.last_op][mdl.last_col]++;
    if (mdl.last_rejected) begin
      for (int b = 0; b < 4; b++) if (mdl.last_cause[b]) cov_cause[b]++;
      if ($countones(mdl.last_cause) > 1) cov_multi_cause++;
      if (pend_clr) cov_clr_hit++;
    end
    if (mdl.last_is_nop) cov_nop++;
  endfunction

  ////////////////////////////////////////////////////////////////////////
  // The monitor: once per cycle, on the falling edge.
  ////////////////////////////////////////////////////////////////////////
  always @(negedge clk) begin
    if (!rst_n) begin
      mdl.reset();
      pend_acc      = 1'b0;
      pend_clr      = 1'b0;
      last_beat_cyc = -1000;
      prev_tv       = 1'b0;
      prev_c        = '0;
      prev_r        = '0;
      prev_x        = '0;
      check_reset_values();
    end else begin
      cyc++;
      applied_word = pend_word;
      mdl.apply(pend_acc, pend_word, pend_clr);
      collect_coverage();
      compare_to_model();
      protocol_checks();
      // what will happen on the next rising edge
      pend_acc  = (s_uop_tvalid === 1'b1) && (s_uop_tready === 1'b1);
      pend_word = s_uop_tdata;
      pend_clr  = (err_clr === 1'b1);
      if (s_uop_tvalid === 1'b1 && s_uop_tready !== 1'b1) cov_stall++;
    end
  end

  ////////////////////////////////////////////////////////////////////////
  // Driver.
  // All driver tasks start and end at "rising edge + 1 ns".
  ////////////////////////////////////////////////////////////////////////
  logic [31:0] q [$];          // words still to send
  int          idle_pct = 0;   // chance of an idle cycle (tvalid = 0)
  int          drop_pct = 0;   // chance to drop tvalid before acceptance
  int          clr_pct  = 0;   // chance of an err_clr pulse in a cycle

  ////////////////////////////////////////////////////////////////////////
  // run_queue - send every word in q. Holds a word until it is taken,
  // unless drop_pct makes it drop tvalid (then the next attempt may even
  // present a different word, which the spec allows). Puts random
  // garbage on s_uop_tdata while tvalid = 0.
  ////////////////////////////////////////////////////////////////////////
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
        if (holding) begin
          cov_drop++;
          if (q.size() > 1 && rnd_pct(50)) begin   // present another word next time
            tmp = q[0]; q[0] = q[1]; q[1] = tmp;
          end
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

  task automatic drain();
    s_uop_tvalid = 1'b0;
    err_clr      = 1'b0;
    idle(BEAT_GAP + 4);
  endtask

  ////////////////////////////////////////////////////////////////////////
  // present_one - drive one word for exactly one cycle (tready must be 1)
  //   w   - the word
  //   clr - err_clr value in the same cycle
  ////////////////////////////////////////////////////////////////////////
  task automatic present_one(input logic [31:0] w, input bit clr);
    s_uop_tvalid = 1'b1;
    s_uop_tdata  = w;
    err_clr      = clr;
    @(negedge clk);
    if (s_uop_tready !== 1'b1) fail("present_one: s_uop_tready is 0, word not taken");
    @(posedge clk);
    #1;
    s_uop_tvalid = 1'b0;
    err_clr      = 1'b0;
  endtask

  task automatic pulse_clr();
    s_uop_tvalid = 1'b0;
    err_clr      = 1'b1;
    @(posedge clk);
    #1;
    err_clr = 1'b0;
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
    beat_log.delete();
    fail_at_start = n_fail;
  endtask

  task automatic end_test();
    drain();
    $display("[%0t] ---- test %s: %s  (words %0d, beats %0d, rejected %0d, config %0d, nop %0d)",
             $time, cur_test, okfail(n_fail == fail_at_start),
             mdl.n_acc, mdl.n_beats, mdl.n_rej, mdl.n_cfg, mdl.n_nop);
  endtask

  ////////////////////////////////////////////////////////////////////////
  // check_beat - literal comparison of logged beat number i
  ////////////////////////////////////////////////////////////////////////
  function void check_beat(input int i, input logic [3*COLS-1:0] c, input logic [3*ROWS-1:0] r,
                           input logic [XBARS-1:0] x, input string name);
    if (beat_log[i].c !== c) fail($sformatf("%s: m_col_tdata = %h, spec says %h", name, beat_log[i].c, c));
    if (beat_log[i].r !== r) fail($sformatf("%s: m_row_tdata = %h, spec says %h", name, beat_log[i].r, r));
    if (beat_log[i].x !== x) fail($sformatf("%s: m_xbar_tdata = %h, spec says %h", name, beat_log[i].x, x));
  endfunction

  ////////////////////////////////////////////////////////////////////////
  // TEST d0 - the worked example of spec section 9, with its literal
  // expected vectors. Needs ROWS = COLS = XBARS = 8.
  ////////////////////////////////////////////////////////////////////////
  task automatic test_d0();
    if (!(ROWS == 8 && COLS == 8 && XBARS == 8)) begin
      $display("[%0t] ---- test d0 skipped (needs ROWS = COLS = XBARS = 8)", $time);
      return;
    end
    start_test("d0");
    q.push_back(32'h00020006);  //  1 SET_CMASK 0 1
    q.push_back(32'h00060008);  //  2 SET_MASK 0 3 col=0
    q.push_back(32'h0000010A);  //  3 SET_BASE DEST 2
    q.push_back(32'h000002AA);  //  4 SET_BASE SRC1 5
    q.push_back(32'h00000005);  //  5 SET DEST+0 .. DEST+0
    q.push_back(32'h00001001);  //  6 NOT DEST+0 <- SRC1+0
    q.push_back(32'h0000006C);  //  7 INC_BASE DEST+SRC1
    q.push_back(32'h00001001);  //  8 NOT DEST+0 <- SRC1+0
    q.push_back(32'h000E0048);  //  9 SET_MASK 0 7 col=1
    q.push_back(32'h00001001);  // 10 NOT DEST+0 <- SRC1+0 (axes swapped)
    q.push_back(32'h0000038A);  // 11 SET_BASE DEST 7
    q.push_back(32'h00001011);  // 12 NOT DEST+1 <- SRC1+0  -> d = 8, out of range
    q.push_back(32'h00000001);  // 13 NOT DEST+0 <- DEST+0  -> d = s1 (Arjun ROM word 144)
    run_queue();
    drain();
    if (beat_log.size() != 4)
      fail($sformatf("spec expects 4 beats, got %0d", beat_log.size()));
    else begin
      check_beat(0, 24'h000080, 24'hFFFB6D, 8'h03, "row 5 SET");
      check_beat(1, 24'h020140, 24'hFFF000, 8'h03, "row 6 NOT");
      check_beat(2, 24'h100A00, 24'hFFF000, 8'h03, "row 8 NOT");
      check_beat(3, 24'h000000, 24'h100A00, 8'h03, "row 10 NOT, axes swapped");
    end
    if (err_sticky !== 1'b1)    fail("spec expects err_sticky = 1 after D0");
    if (err_cause  !== 4'b0011) fail($sformatf("spec expects err_cause = 0011 after D0, got %b", err_cause));
    if (dbg_dest !== 10'd7 || dbg_src1 !== 10'd6)
      fail($sformatf("after D0: dbg_dest = %0d (7), dbg_src1 = %0d (6)", dbg_dest, dbg_src1));
    if (dbg_col !== 1'b1 || dbg_m_start !== 10'd0 || dbg_m_end !== 10'd7 || dbg_m_vld !== 1'b1)
      fail("after D0: mask registers differ from the spec (col=1, 0..7, valid)");
    if (dbg_c_start !== 10'd0 || dbg_c_end !== 10'd1 || dbg_c_vld !== 1'b1)
      fail("after D0: crossbar registers differ from the spec (0..1, valid)");
    end_test();
  endtask

  ////////////////////////////////////////////////////////////////////////
  // TEST waveform - the table in spec section 7 (BEAT_GAP = 2 only):
  // SET_BASE, NOT, NOT with tvalid held high.
  ////////////////////////////////////////////////////////////////////////
  task automatic test_waveform();
    logic [31:0]       base_w, not1, not2;
    bit                tr [5];
    bit                tv [5];
    int                dd [5];
    logic [3*COLS-1:0] cd [5];
    bit                exp_tr [5] = '{1, 1, 0, 1, 0};
    bit                exp_tv [5] = '{0, 0, 1, 0, 1};
    if (BEAT_GAP != 2 || COLS < 4) begin
      $display("[%0t] ---- test waveform skipped (needs BEAT_GAP = 2, COLS >= 4)", $time);
      return;
    end
    start_test("waveform");
    q.push_back(enc_set_base(SEL_SRC1, COLS - 1));     // makes the two NOTs legal
    run_queue();
    idle(3);
    base_w = enc_set_base(SEL_DEST, 1);                // "BASE"
    not1   = enc_not(1'b0, 0, SEL_SRC1, 0);            // NOT line 1 <- line COLS-1
    not2   = enc_not(1'b0, 1, SEL_SRC1, 0);            // NOT line 2 <- line COLS-1
    s_uop_tvalid = 1'b1;  s_uop_tdata = base_w;        // cycle 0
    @(negedge clk);  tr[0] = s_uop_tready;  tv[0] = m_col_tvalid;  dd[0] = dbg_dest;  cd[0] = m_col_tdata;
    @(posedge clk);  #1;  s_uop_tdata = not1;          // cycle 1
    @(negedge clk);  tr[1] = s_uop_tready;  tv[1] = m_col_tvalid;  dd[1] = dbg_dest;  cd[1] = m_col_tdata;
    @(posedge clk);  #1;  s_uop_tdata = not2;          // cycle 2
    @(negedge clk);  tr[2] = s_uop_tready;  tv[2] = m_col_tvalid;  dd[2] = dbg_dest;  cd[2] = m_col_tdata;
    @(posedge clk);  #1;                               // cycle 3 (NOT2 still held)
    @(negedge clk);  tr[3] = s_uop_tready;  tv[3] = m_col_tvalid;  dd[3] = dbg_dest;  cd[3] = m_col_tdata;
    @(posedge clk);  #1;  s_uop_tvalid = 1'b0;         // cycle 4
    @(negedge clk);  tr[4] = s_uop_tready;  tv[4] = m_col_tvalid;  dd[4] = dbg_dest;  cd[4] = m_col_tdata;
    @(posedge clk);  #1;
    for (int k = 0; k < 5; k++) begin
      if (tr[k] !== exp_tr[k]) fail($sformatf("cycle %0d: s_uop_tready = %b, spec table says %b", k, tr[k], exp_tr[k]));
      if (tv[k] !== exp_tv[k]) fail($sformatf("cycle %0d: m_*_tvalid = %b, spec table says %b",   k, tv[k], exp_tv[k]));
    end
    if (dd[0] != 0)                                       fail("cycle 0: dbg_dest should still be old (0)");
    if (dd[1] != 1 || dd[2] != 1 || dd[3] != 1 || dd[4] != 1) fail("cycles 1-4: dbg_dest should be new (1)");
    if (cd[3] !== cd[2]) fail("cycle 3: m_*_tdata must still hold NOT1");
    if (cd[4] === cd[2]) fail("cycle 4: m_*_tdata must show NOT2");
    end_test();
  endtask

  ////////////////////////////////////////////////////////////////////////
  // TEST before_cfg - memory ops before any SET_MASK / SET_CMASK:
  // beats are sent, mask axis all 111, xbar 0, and no error (spec 5, 8).
  ////////////////////////////////////////////////////////////////////////
  task automatic test_before_cfg();
    if (COLS < 2 || ROWS < 2) return;
    start_test("before_cfg");
    q.push_back(enc_set_base(SEL_SRC1, 1));
    q.push_back(enc_not(1'b0, 0, SEL_SRC1, 0));                   // d = 0, s1 = 1
    q.push_back(enc_set(SEL_DEST, 0, SEL_SRC1, 0));               // SET 0..1
    q.push_back(enc_reset(SEL_SRC1, 0, SEL_DEST, 0));             // RESET 1..0
    q.push_back(enc_nor(1'b0, 0, SEL_SRC1, 0, SEL_SRC1, 0));      // NOR with s1 = s2
    q.push_back(enc_set_cmask(0, XBARS - 1));                     // crossbars, still no mask
    q.push_back(enc_not(1'b0, 0, SEL_SRC1, 0));
    run_queue();
    drain();
    if (beat_log.size() != 5) fail($sformatf("expected 5 beats, got %0d", beat_log.size()));
    if (err_sticky !== 1'b0)  fail("a memory op before SET_MASK/SET_CMASK must not be an error");
    // fresh start: only a mask, no crossbar mask
    do_reset();
    q.push_back(enc_set_mask(0, 0, 1'b0));
    q.push_back(enc_set_base(SEL_SRC1, 1));
    q.push_back(enc_not(1'b0, 0, SEL_SRC1, 0));
    run_queue();
    drain();
    if (err_sticky !== 1'b0)  fail("a memory op before SET_CMASK must not be an error");
    end_test();
  endtask

  ////////////////////////////////////////////////////////////////////////
  // TEST ops - every op on both axes, every base-register select,
  // ranges forward / reversed / single / full, partial and reversed masks.
  // The model checks the exact vectors.
  ////////////////////////////////////////////////////////////////////////
  task automatic test_ops();
    int nop, nm;
    start_test("ops");
    for (int ax = 0; ax < 2; ax++) begin
      nop = ax ? ROWS : COLS;
      nm  = ax ? COLS : ROWS;
      q.push_back(enc_set_cmask(XBARS - 1, 0));              // reversed (swapped)
      q.push_back(enc_set_mask(nm - 1, 0, 1'(ax)));          // reversed full mask
      q.push_back(enc_set_base(SEL_DEST, 0));
      q.push_back(enc_set_base(SEL_SRC1, nop - 1));
      q.push_back(enc_set_base(SEL_SRC2, nop / 2));
      q.push_back(enc_set_base(SEL_TEMP, 1));
      // SET / RESET ranges
      q.push_back(enc_set  (SEL_DEST, 0, SEL_DEST, 0));      // single line 0
      q.push_back(enc_set  (SEL_DEST, 0, SEL_SRC1, 0));      // 0 .. nop-1 (full)
      q.push_back(enc_set  (SEL_SRC1, 0, SEL_DEST, 0));      // reversed full
      q.push_back(enc_set  (SEL_TEMP, 0, SEL_SRC2, 0));      // 1 .. nop/2
      q.push_back(enc_reset(SEL_SRC2, 0, SEL_TEMP, 0));      // reversed
      q.push_back(enc_reset(SEL_SRC1, 0, SEL_SRC1, 0));      // last line only
      // NOT / NOR with each select
      q.push_back(enc_not(1'b0, 0, SEL_SRC1, 0));            // d = 0, s = nop-1
      q.push_back(enc_not(1'b1, 0, SEL_SRC2, 0));            // d = TEMP, s = nop/2
      q.push_back(enc_not(1'b1, 1, SEL_DEST, 0));            // d = TEMP+1, s = DEST
      q.push_back(enc_mem(OP_NOT, 1'b0, 0, SEL_SRC1, 0, SEL_TEMP, 255)); // src2 ignored
      q.push_back(enc_nor(1'b0, 0, SEL_SRC1, 0, SEL_SRC2, 0));
      q.push_back(enc_nor(1'b1, 0, SEL_SRC1, 0, SEL_SRC1, 0));           // s1 = s2
      q.push_back(enc_nor(1'b0, 0, SEL_TEMP, 0, SEL_TEMP, 1));
      // partial masks and crossbar ranges
      q.push_back(enc_set_mask(nm - 1, nm / 2, 1'(ax)));
      q.push_back(enc_set_cmask(XBARS / 2, XBARS / 2));
      q.push_back(enc_set(SEL_TEMP, 0, SEL_TEMP, 1));
      q.push_back(enc_not(1'b0, 0, SEL_SRC1, 0));
      q.push_back(enc_set_mask(0, 0, 1'(ax)));
      q.push_back(enc_set_cmask(0, XBARS - 1));
      q.push_back(enc_reset(SEL_DEST, 0, SEL_SRC1, 0));
      q.push_back(enc_nor(1'b0, 0, SEL_SRC1, 0, SEL_SRC2, 0));
    end
    run_queue();
    end_test();
  endtask

  ////////////////////////////////////////////////////////////////////////
  // TEST errors - each err_cause bit, boundaries, 11-bit compare,
  // rejected configs leave the registers unchanged (model checks dbg_*).
  ////////////////////////////////////////////////////////////////////////
  task automatic test_errors();
    if (COLS < 4 || ROWS < 2 || XBARS < 1) return;
    start_test("errors");
    // col = 0: N_op = COLS, N_mask = ROWS
    q.push_back(enc_set_mask(0, ROWS - 1, 1'b0));
    q.push_back(enc_set_cmask(0, XBARS - 1));
    q.push_back(enc_set_base(SEL_DEST, COLS - 1));
    q.push_back(enc_set_base(SEL_SRC1, 0));
    q.push_back(enc_set_base(SEL_SRC2, 1));
    q.push_back(enc_not(1'b0, 0, SEL_SRC1, 0));                           // legal: d is the last line
    q.push_back(enc_not(1'b0, 1, SEL_SRC1, 0));                           // d = COLS        -> [0]
    q.push_back(enc_not(1'b0, 0, SEL_DEST, 1));                           // s1 = COLS       -> [0]
    q.push_back(enc_mem(OP_NOT, 1'b0, 0, SEL_SRC2, 0, SEL_DEST, 200));    // bad src2 ignored -> legal
    q.push_back(enc_nor(1'b0, 0, SEL_SRC2, 0, SEL_DEST, 1));              // s2 = COLS       -> [0]
    q.push_back(enc_nor(1'b0, 0, SEL_SRC2, 0, SEL_DEST, 0));              // d = s2          -> [1]
    q.push_back(enc_nor(1'b0, 1, SEL_SRC2, 0, SEL_DEST, 1));              // d = s2 = COLS   -> [0] and [1]
    q.push_back(enc_not(1'b0, 0, SEL_DEST, 0));                           // d = s1          -> [1]
    q.push_back(enc_set  (SEL_SRC1, 0, SEL_DEST, 1));                     // hi = COLS       -> [0]
    q.push_back(enc_reset(SEL_DEST, 1, SEL_SRC1, 0));                     // reversed, hi = COLS -> [0]
    q.push_back(enc_set  (SEL_SRC1, 0, SEL_DEST, 0));                     // 0..COLS-1, legal
    q.push_back(enc_mem(OP_SET, 1'b1, 255, SEL_SRC1, 0, SEL_SRC2, 0));    // bad dest ignored -> legal
    // no wrap at 10 bits: 1023 + 1 = 1024 would wrap to 0
    q.push_back(enc_set_base(SEL_DEST, 1023));
    q.push_back(enc_not(1'b0, 1,   SEL_SRC2, 0));                         // d = 1024        -> [0]
    q.push_back(enc_not(1'b0, 255, SEL_SRC2, 0));                         // d = 1278        -> [0]
    q.push_back(enc_set(SEL_DEST, 1, SEL_DEST, 1));                       // 1024..1024      -> [0]
    // INC_BASE wraps 1023 -> 0 (not an error)
    q.push_back(enc_inc_base(1, 0, 0, 0));
    q.push_back(enc_not(1'b0, 0, SEL_SRC2, 0));                           // d = 0, s = 1, legal
    // bad SET_MASK: rejected, registers unchanged
    q.push_back(enc_set_mask(0, ROWS, 1'b0));                             // -> [2]
    q.push_back(enc_set_mask(ROWS, 0, 1'b0));                             // reversed        -> [2]
    q.push_back(enc_set_mask(0, COLS, 1'b1));                             // -> [2]
    if (ROWS != COLS) begin
      // legal for one axis but not the other: the col field of the word decides
      q.push_back(enc_set_mask(0, imax(ROWS, COLS) - 1, (COLS > ROWS) ? 1'b0 : 1'b1));  // -> [2]
      q.push_back(enc_set_mask(0, imax(ROWS, COLS) - 1, (COLS > ROWS) ? 1'b1 : 1'b0));  // legal
    end
    q.push_back(enc_not(1'b0, 0, SEL_SRC2, 0));                           // uses the current mask
    // bad SET_CMASK
    q.push_back(enc_set_cmask(0, XBARS));                                 // -> [3]
    q.push_back(enc_set_cmask(XBARS, XBARS));                             // -> [3]
    q.push_back(enc_set_cmask(1023, 0));                                  // -> [3]
    q.push_back(enc_not(1'b0, 0, SEL_SRC2, 0));                           // old crossbar range
    q.push_back(enc_set_cmask(XBARS - 1, 0));                             // reversed, legal
    q.push_back(enc_set_mask(0, 0, 1'b0));
    q.push_back(enc_not(1'b0, 0, SEL_SRC2, 0));
    run_queue();
    drain();
    if (err_sticky !== 1'b1)    fail("err_sticky should be 1 after the error test");
    if (err_cause  !== 4'b1111) fail($sformatf("every cause bit was triggered, err_cause = %b", err_cause));
    end_test();
  endtask

  ////////////////////////////////////////////////////////////////////////
  // TEST err_clr - clearing, and err_clr on the same edge as a new error.
  // The literal checks here follow interpretation I1 (README):
  //   err_cause <= (err_clr ? 0 : err_cause) | new_cause
  ////////////////////////////////////////////////////////////////////////
  task automatic test_err_clr();
    start_test("err_clr");
    present_one(enc_set_cmask(0, XBARS), 1'b0);               // cause [3]
    idle(2);
    if (err_sticky !== 1'b1 || err_cause !== 4'b1000) fail($sformatf("after bad SET_CMASK: sticky=%b cause=%b", err_sticky, err_cause));
    pulse_clr();
    idle(2);
    if (err_sticky !== 1'b0 || err_cause !== 4'b0000) fail($sformatf("after err_clr: sticky=%b cause=%b", err_sticky, err_cause));
    present_one(32'h00000001, 1'b0);                          // NOT d = s1 = 0 -> cause [1]
    idle(2);
    if (err_cause !== 4'b0010) fail($sformatf("after d = s1: cause=%b (0010)", err_cause));
    present_one(enc_set_cmask(0, XBARS), 1'b1);               // new error together with err_clr
    idle(2);
    if (err_sticky !== 1'b1 || err_cause !== 4'b1000)
      fail($sformatf("err_clr + new error on one edge: sticky=%b cause=%b, expected 1 / 1000 (error wins, old bit cleared)",
                     err_sticky, err_cause));
    pulse_clr();
    idle(2);
    // back-to-back rejected config words: err_pulse high in consecutive cycles
    q.push_back(enc_set_cmask(0, XBARS));
    q.push_back(enc_set_mask(0, ROWS, 1'b0));
    q.push_back(enc_set_base(SEL_TEMP, 3));
    q.push_back(enc_set_cmask(XBARS, 0));
    run_queue();
    // random clears during traffic
    for (int i = 0; i < 300; i++) q.push_back(rnd_word(ROWS, COLS, XBARS));
    clr_pct = 10;
    run_queue();
    end_test();
  endtask

  ////////////////////////////////////////////////////////////////////////
  // TEST nops - every non-config type-0 opcode (with all-ones and random
  // upper bits) and Arjun's control words: no beat, no error, no change.
  ////////////////////////////////////////////////////////////////////////
  task automatic test_nops();
    int ops [12] = '{0, 1, 2, 7, 8, 9, 10, 11, 12, 13, 14, 15};
    start_test("nops");
    q.push_back(enc_set_mask(0, ROWS - 1, 1'b0));
    q.push_back(enc_set_cmask(0, XBARS - 1));
    q.push_back(enc_set_base(SEL_SRC1, 1));
    foreach (ops[k]) q.push_back(32'hFFFF_FFE0 | (32'(ops[k]) << 1));
    for (int i = 0; i < 300; i++) q.push_back(rnd_nop_word());
    q.push_back(enc_not(1'b0, 0, SEL_SRC1, 0));   // state must be unchanged
    run_queue();
    drain();
    if (err_sticky !== 1'b0) fail("a NOP word raised an error");
    end_test();
  endtask

  ////////////////////////////////////////////////////////////////////////
  // TEST reserved_bits - bits not listed for an op are ignored (spec 4)
  ////////////////////////////////////////////////////////////////////////
  task automatic test_reserved_bits();
    if (COLS < 2) return;
    start_test("reserved_bits");
    q.push_back(enc_set_cmask(0, XBARS - 1)   | 32'hF800_0060);   // [31:27], [6:5]
    q.push_back(enc_set_mask(0, ROWS - 1, 0)  | 32'hF800_0020);   // [31:27], [5]
    q.push_back(enc_set_base(SEL_SRC1, 1)     | 32'hFFFE_0000);   // [31:17]
    q.push_back(enc_inc_base(0, 0, 0, 1)      | 32'hFFFF_FE00);   // [31:9]
    q.push_back(enc_mem(OP_NOT, 1'b0, 0, SEL_SRC1, 0, SEL_TEMP, 255)); // src2 of NOT ignored
    q.push_back(enc_mem(OP_SET, 1'b1, 255, SEL_DEST, 0, SEL_SRC1, 0)); // dest of SET ignored
    run_queue();
    drain();
    if (err_sticky !== 1'b0) fail("garbage in unlisted bits caused an error");
    end_test();
  endtask

  ////////////////////////////////////////////////////////////////////////
  // TEST tvalid_drop - words on the bus with tvalid = 0 are never taken;
  // tvalid dropped before acceptance; idle gaps.
  ////////////////////////////////////////////////////////////////////////
  task automatic test_tvalid_drop();
    start_test("tvalid_drop");
    repeat (40) begin
      s_uop_tvalid = 1'b0;
      s_uop_tdata  = $urandom_range(0, 1) ? enc_set_base(2'($urandom_range(0, 3)), $urandom_range(1, 1023))
                                          : rnd_word(ROWS, COLS, XBARS);
      @(posedge clk);
      #1;
    end
    // (the model saw no acceptance, so every dbg_* must still be 0)
    for (int i = 0; i < 500; i++) q.push_back(rnd_word(ROWS, COLS, XBARS));
    idle_pct = 30;
    drop_pct = 40;
    run_queue();
    end_test();
  endtask

  ////////////////////////////////////////////////////////////////////////
  // TEST back_to_back - tvalid always high, a long run of legal beats:
  // exact BEAT_GAP spacing, order and count.
  ////////////////////////////////////////////////////////////////////////
  task automatic test_back_to_back();
    if (COLS < 3) return;
    start_test("back_to_back");
    q.push_back(enc_set_mask(0, ROWS - 1, 1'b0));
    q.push_back(enc_set_cmask(0, XBARS - 1));
    q.push_back(enc_set_base(SEL_DEST, 0));
    q.push_back(enc_set_base(SEL_SRC1, 1));
    q.push_back(enc_set_base(SEL_SRC2, 2));
    for (int i = 0; i < 100; i++) begin
      q.push_back(enc_not(1'b0, 0, SEL_SRC1, 0));
      q.push_back(enc_nor(1'b0, 0, SEL_SRC1, 0, SEL_SRC2, 0));
      q.push_back(enc_set(SEL_SRC1, 0, SEL_SRC2, 0));
    end
    run_queue();
    drain();
    if (beat_log.size() != 300) fail($sformatf("expected 300 beats, got %0d", beat_log.size()));
    end_test();
  endtask

  ////////////////////////////////////////////////////////////////////////
  // TEST random - N_RANDOM random words with random idle cycles, tvalid
  // drops and err_clr pulses
  ////////////////////////////////////////////////////////////////////////
  task automatic test_random();
    start_test("random");
    for (int i = 0; i < N_RANDOM; i++) q.push_back(rnd_word(ROWS, COLS, XBARS));
    idle_pct = 20;
    drop_pct = 15;
    clr_pct  = 3;
    run_queue();
    end_test();
  endtask

  ////////////////////////////////////////////////////////////////////////
  // TEST reset_mid - asynchronous reset in the middle of traffic
  ////////////////////////////////////////////////////////////////////////
  task automatic test_reset_mid();
    start_test("reset_mid");
    for (int i = 0; i < 400; i++) q.push_back(rnd_word(ROWS, COLS, XBARS));
    idle_pct = 10;
    fork
      run_queue();
      begin
        repeat (150) @(posedge clk);
        #1 rst_n = 1'b0;
        repeat (2) @(posedge clk);
        #1 rst_n = 1'b1;
      end
    join
    end_test();
  endtask

  function automatic bit want(input string tsel, input string name);
    return (tsel == "all") || (tsel == name);
  endfunction

  ////////////////////////////////////////////////////////////////////////
  // Main
  ////////////////////////////////////////////////////////////////////////
  initial begin
    string tsel;
    mdl = new();
    if (!$value$plusargs("TEST=%s", tsel)) tsel = "all";
    // Random seed: xsim does not support $urandom(seed); set it with the
    // xsim option  -sv_seed <n>  (run_tb.bat / create_sim_project.tcl do).
    $display("==== tb_uop2vec  ROWS=%0d COLS=%0d XBARS=%0d BEAT_GAP=%0d  TEST=%s ====",
             ROWS, COLS, XBARS, BEAT_GAP, tsel);
    if (check_encoders() != 0) fail("testbench encoders do not match the spec examples");

    if (want(tsel, "d0"))            test_d0();
    if (want(tsel, "waveform"))      test_waveform();
    if (want(tsel, "before_cfg"))    test_before_cfg();
    if (want(tsel, "ops"))           test_ops();
    if (want(tsel, "errors"))        test_errors();
    if (want(tsel, "err_clr"))       test_err_clr();
    if (want(tsel, "nops"))          test_nops();
    if (want(tsel, "reserved_bits")) test_reserved_bits();
    if (want(tsel, "tvalid_drop"))   test_tvalid_drop();
    if (want(tsel, "back_to_back"))  test_back_to_back();
    if (want(tsel, "random"))        test_random();
    if (want(tsel, "reset_mid"))     test_reset_mid();

    $display("---- coverage ----");
    for (int op = 0; op < 4; op++)
      for (int c = 0; c < 2; c++) begin
        $display("  beats  op=%s col=%0d : %0d", op_name(op), c, cov_beat[op][c]);
        if (cov_beat[op][c] == 0) $display("  WARNING: coverage hole (no beat of this kind)");
      end
    for (int b = 0; b < 4; b++) begin
      $display("  err_cause[%0d] hits : %0d", b, cov_cause[b]);
      if (cov_cause[b] == 0) $display("  WARNING: coverage hole (cause bit never triggered)");
    end
    $display("  multi-cause words %0d | err_clr + error same edge %0d | NOPs %0d | stalls %0d | drops %0d",
             cov_multi_cause, cov_clr_hit, cov_nop, cov_stall, cov_drop);

    if (n_fail == 0) begin
      $display("*** TEST PASSED ***");
      $finish;
    end else begin
      $display("*** TEST FAILED: %0d check failures ***", n_fail);
      $fatal(1, "tb_uop2vec failed");
    end
  end

endmodule
