`default_nettype none

// SDRAM DQ with every register in the pad: per bit an ODDR for data (OLOGIC OUTFF), an ODDR
// for the tristate (OLOGIC TFF) and an IDDR for read data (ILOGIC). Pin timing is then fixed
// by the I/O tile and does not depend on placement. Explicit primitives: the IOB attribute
// on fabric registers did not pack reliably here (shared CE/SR rules).
// Latency, clk edge c: dq_oe_d/dq_out at c reach the pin at c (the register is the pad);
// dq_in is the pin sampled at the previous rising edge (one register).
// Only for a single controller driving the pins directly (no owner mux after it).
// InDelayTaps > 0: fixed IDELAYE2 on each DQ input (needs an IDELAYCTRL with a
// RefMhz reference clock in the design); the tap delay is 1 / (64 * RefMhz).
module retro_sdram_phy #(
    parameter int InDelayTaps = 0,
    parameter real RefMhz = 200.0
) (
    input  wire        clk,
    input  wire [31:0] dq_out,   // write data, stable through the WRITE cycle
    input  wire        dq_oe_d,  // next-cycle drive enable (D of the controller's dq_oe)
    output wire [31:0] dq_in,    // pin captured at the previous clk rising edge
    inout  wire [31:0] sd_dq
);
  for (genvar i = 0; i < 32; i++) begin : g_bit
    wire o, t, d1, d_in;
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .SRTYPE("SYNC")) u_o (
        .Q(o), .C(clk), .CE(1'b1), .D1(dq_out[i]), .D2(dq_out[i]), .R(1'b0), .S(1'b0));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .SRTYPE("SYNC")) u_t (
        .Q(t), .C(clk), .CE(1'b1), .D1(!dq_oe_d), .D2(!dq_oe_d), .R(1'b0), .S(1'b0));
    IOBUF u_io (.IO(sd_dq[i]), .I(o), .T(t), .O(d1));
    if (InDelayTaps > 0) begin : g_delay
      IDELAYE2 #(.IDELAY_TYPE("FIXED"), .IDELAY_VALUE(InDelayTaps), .DELAY_SRC("IDATAIN"),
          .HIGH_PERFORMANCE_MODE("TRUE"), .SIGNAL_PATTERN("DATA"),
          .REFCLK_FREQUENCY(RefMhz), .CINVCTRL_SEL("FALSE"), .PIPE_SEL("FALSE")) u_d (
          .IDATAIN(d1), .DATAOUT(d_in), .C(1'b0), .CE(1'b0), .INC(1'b0), .LD(1'b0),
          .LDPIPEEN(1'b0), .REGRST(1'b0), .CINVCTRL(1'b0), .CNTVALUEIN(5'd0),
          .CNTVALUEOUT(), .DATAIN(1'b0));
    end else begin : g_direct
      assign d_in = d1;
    end
    IDDR #(.DDR_CLK_EDGE("SAME_EDGE"), .SRTYPE("SYNC")) u_i (
        .Q1(dq_in[i]), .Q2(), .C(clk), .CE(1'b1), .D(d_in), .R(1'b0), .S(1'b0));
  end
endmodule
`default_nettype wire
