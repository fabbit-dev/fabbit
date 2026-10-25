`default_nettype none

// UG471 IDDR SAME_EDGE_PIPELINED: Q1 (rising) precedes Q2 (falling) in each pair.
// Both lanes get the same settling pipeline. No filtering, no BITSLIP, no clock-domain crossing.
module la_sampler #(
    parameter bit Ddr = 1'b0,
    localparam int K = Ddr ? 2 : 1
) (
    input  wire            clk,
    input  wire            rst,
    input  wire [15:0]     probe,
    output logic           valid,
    output logic [16*K-1:0] samples
);
  wire [16*K-1:0] captured;
  if (Ddr) begin : g_ddr
    for (genvar i = 0; i < 16; i++) begin : g_pin
      IDDR #(.DDR_CLK_EDGE("SAME_EDGE_PIPELINED"), .SRTYPE("SYNC"),
             .INIT_Q1(1'b0), .INIT_Q2(1'b0)) u_iddr (
          .C(clk), .CE(1'b1), .D(probe[i]), .R(rst), .S(1'b0),
          .Q1(captured[i]), .Q2(captured[16+i]));
    end
  end else begin : g_sdr
    (* IOB = "TRUE" *) logic [15:0] probe_iob;
    always_ff @(posedge clk) probe_iob <= probe;
    assign captured = probe_iob;
  end
  logic [3:0] warmup = 4'd0;
  always_ff @(posedge clk) begin
    samples <= captured;
    if (rst) begin
      warmup <= 4'd0;
      valid <= 1'b0;
    end else begin
      warmup <= {warmup[2:0], 1'b1};
      valid <= &warmup;
    end
  end
endmodule
