//////////////////////////////////////////////////////////////////////////////
/// File    : beat_out.sv
/// Module  : beat_out
///
/// Output stage towards memarray_top. On a legal memory op it registers
/// the three vectors and raises beat_valid for exactly one cycle; the data
/// then holds until the next beat. It also paces the input: after a beat,
/// uop_ready is low for BEAT_GAP-1 cycles, so beats are at least BEAT_GAP
/// cycles apart. Config ops, NOPs and rejected words never lower uop_ready.
//////////////////////////////////////////////////////////////////////////////

module beat_out #(
  parameter int ROWS     = 32,
  parameter int COLS     = 32,
  parameter int XBARS    = 8,
  parameter int BEAT_GAP = 2
)
(
  input  logic              clk,
  input  logic              rst_n,

  // legal memory op accepted this cycle
  input  logic              beat_fire,

  // vectors from vec_gen
  input  logic [3*COLS-1:0] col_vec,
  input  logic [3*ROWS-1:0] row_vec,
  input  logic [XBARS-1:0]  xbar_vec,

  // registered beat
  output logic [3*COLS-1:0] col_data,
  output logic [3*ROWS-1:0] row_data,
  output logic [XBARS-1:0]  xbar_data,
  output logic              beat_valid,

  // input pacing
  output logic              uop_ready
);


  //////////////////////////////////////////////////////////////////////////
  /// Beat register
  //////////////////////////////////////////////////////////////////////////

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      col_data   <= '0;
      row_data   <= '0;
      xbar_data  <= '0;
      beat_valid <= 1'b0;
    end
    else begin
      beat_valid <= beat_fire;

      if (beat_fire) begin
        col_data  <= col_vec;
        row_data  <= row_vec;
        xbar_data <= xbar_vec;
      end
    end
  end


  //////////////////////////////////////////////////////////////////////////
  /// Beat-gap counter
  /// Loaded with BEAT_GAP-1 on a beat, counts down to 0; ready when 0.
  /// BEAT_GAP = 1 keeps uop_ready high (back-to-back beats).
  //////////////////////////////////////////////////////////////////////////

  localparam int CNT_W = (BEAT_GAP > 1) ? $clog2(BEAT_GAP) : 1;

  localparam logic [CNT_W-1:0] GAP_LOAD = CNT_W'(BEAT_GAP - 1);

  logic [CNT_W-1:0] gap_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      gap_cnt <= '0;
    end
    else if (beat_fire) begin
      gap_cnt <= GAP_LOAD;
    end
    else if (gap_cnt != '0) begin
      gap_cnt <= gap_cnt - 1'b1;
    end
  end

  assign uop_ready = (gap_cnt == '0);


endmodule
