`default_nettype none

// UG471 IDDR SAME_EDGE_PIPELINED: Q1 (rising) precedes Q2 (falling) in each pair.
// ISERDESE2 DDR 1:4: reverse Q4..Q1 into oldest-first lanes (checked against AMD SecureIP).
// All lanes get the same settling pipeline. No filtering or BITSLIP.
module la_sampler #(
    parameter bit Ddr = 1'b0,
    parameter bit Serdes = 1'b0,
    localparam int K = Serdes ? 4 : (Ddr ? 2 : 1)
) (
    input  wire            clk,
    input  wire            clk_fast,  // 200 MHz; CLKDIV=clk at 100 MHz, same PLL + BUFGs
    input  wire            rst,
    input  wire [15:0]     probe,
    output logic           valid,
    output logic [16*K-1:0] samples
);
  wire [16*K-1:0] captured;
  if (Serdes) begin : g_serdes
    for (genvar i = 0; i < 16; i++) begin : g_pin
      ISERDESE2 #(.DATA_RATE("DDR"), .DATA_WIDTH(4), .INTERFACE_TYPE("NETWORKING"),
                  .IOBDELAY("NONE"), .NUM_CE(1), .SERDES_MODE("MASTER")) u_serdes (
          .CLK(clk_fast), .CLKB(~clk_fast), .CLKDIV(clk), .CLKDIVP(1'b0),
          .D(probe[i]), .DDLY(1'b0), .RST(rst), .BITSLIP(1'b0), .CE1(1'b1), .CE2(1'b1),
          .DYNCLKDIVSEL(1'b0), .DYNCLKSEL(1'b0), .OCLK(1'b0), .OCLKB(1'b0), .OFB(1'b0),
          .SHIFTIN1(1'b0), .SHIFTIN2(1'b0), .SHIFTOUT1(), .SHIFTOUT2(), .O(),
          .Q1(captured[48+i]), .Q2(captured[32+i]),
          .Q3(captured[16+i]), .Q4(captured[i]), .Q5(), .Q6(), .Q7(), .Q8());
    end
  end else if (Ddr) begin : g_ddr
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
