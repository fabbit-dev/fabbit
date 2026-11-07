// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// Source = retro_clocks SNES output, 21.4772727MHz. VCO = source*36 = 773.2 MHz;
// service /12 (64.43 MHz, 3 x master), master /36 (50% duty), SDRAM clock /12.
// Rising edges of service and master coincide (s0). SDRAM clock -93.75 deg: 4.04 ns
// earlier than service. Datasheet I/O STA (ESMT -7, board 0.2-0.8 ns, constraints/
// retro_sdram_io_timing.xdc): outputs pass only for 3.76..4.24 ns early. Read data
// is captured at READ+3 behind a fixed IDELAY (retro_sdram_phy InDelayTaps) that
// restores input hold. idelay_ref: VCO/4 = 193.3 MHz for IDELAYCTRL (190-210 MHz).
// Board (diag retro_sdram_eye_snes3_prod, this exact PHY): error-free 15.15 of
// 15.52 ns, nearest failing phase 4.25 ns away; soak 200 s at this phase, 0 errors.
module retro_snes_clocks #(
    parameter real MemoryPhase = -93.75
) (
    input wire clk_source, reset,
    output wire service, master, memory_clock, idelay_ref, locked,
    output wire master_ce
);
  wire fb,fb_buf,fast_raw,master_raw,phase_raw,ref_raw;
  // clk_source already traverses a BUFG; feedback is local to this MMCM.
  MMCME2_ADV #(.COMPENSATION("BUF_IN"),
      .CLKIN1_PERIOD(46.56084656),.DIVCLK_DIVIDE(1),.CLKFBOUT_MULT_F(36.0),
      .CLKOUT0_DIVIDE_F(12.0),.CLKOUT1_DIVIDE(36),.CLKOUT2_DIVIDE(12),
      .CLKOUT2_PHASE(MemoryPhase),.CLKOUT3_DIVIDE(4)) mmcm (
      .CLKIN1(clk_source),.CLKIN2(1'b0),.CLKINSEL(1'b1),.CLKFBIN(fb_buf),.CLKFBOUT(fb),
      .CLKOUT0(fast_raw),.CLKOUT1(master_raw),.CLKOUT2(phase_raw),.LOCKED(locked),
      .RST(reset),.PWRDWN(1'b0),.PSCLK(1'b0),.PSEN(1'b0),.PSINCDEC(1'b0),
      .DADDR(7'b0),.DCLK(1'b0),.DEN(1'b0),.DI(16'b0),.DWE(1'b0),
      .CLKFBOUTB(),.CLKOUT0B(),.CLKOUT1B(),.CLKOUT2B(),.CLKOUT3(ref_raw),.CLKOUT3B(),
      .CLKOUT4(),.CLKOUT5(),.CLKOUT6(),.PSDONE(),.DO(),.DRDY(),.CLKINSTOPPED(),.CLKFBSTOPPED());
  // Match BUF_IN's required buffered feedback without another global BUFG.
  BUFH feedback_buffer (.I(fb),.O(fb_buf));
  BUFG fast_buffer (.I(fast_raw),.O(service));
  BUFG master_buffer (.I(master_raw),.O(master));
  BUFG phase_buffer (.I(phase_raw),.O(memory_clock));
  BUFG idelay_buffer (.I(ref_raw),.O(idelay_ref));
  // master_ce: high in the service cycle before s0. A master-domain toggle
  // (launched at s0) is sampled by service at s1 (one service period, timed
  // normally); its change seen between s1 and s2 marks the cycle s2..s0.
  logic toggle=0, t1=0, t2=0, ce=0;
  always_ff @(posedge master) toggle<=!toggle;
  always_ff @(posedge service) begin
    t1<=toggle; t2<=t1;
    ce<=locked && t1!=t2;
  end
  assign master_ce=ce;
endmodule
`default_nettype wire
