// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// Source = retro_clocks SNES output, 21.4772727MHz. VCO = source*36 = 773.2 MHz;
// service /12 (64.43 MHz, 3 x master), master /36 (50% duty), SDRAM clock /12.
// Rising edges of service and master coincide (s0). SDRAM clock starts at -93.75 deg
// (4.04 ns earlier than service): datasheet I/O STA (ESMT -7, board 0.2-0.8 ns,
// constraints/retro_sdram_io_timing.xdc) passes there. Read data is captured at READ+3
// behind a fixed IDELAY (retro_sdram_phy InDelayTaps). idelay_ref: VCO/4 = 193.3 MHz
// for IDELAYCTRL (190-210 MHz).
// The SDRAM clock has the MMCM fine phase shift (VCO/56 = 23.09 ps, 672 steps per
// period, ps_* on the service clock): retro_sdram_calibrate moves it to the middle of
// the window measured on the board at power-up. Board (diag retro_sdram_eye_snes3_train,
// back-to-back reads): window 9.24 ns, from -5.36 to +3.70 ns around the start phase.
// The old idle-gap eye showed 15.15 ns: DQ lines hold the last level after release.
module retro_snes_clocks #(
    parameter real MemoryPhase = -93.75
) (
    input wire clk_source, reset,
    output wire service, master, memory_clock, idelay_ref, locked,
    output wire master_ce,
    // Fine phase shift of memory_clock, synchronous to service: one ps_en per step.
    input wire ps_en, ps_incdec,
    output wire ps_done
);
  wire fb,fb_buf,fast_raw,master_raw,phase_raw,ref_raw;
  // clk_source already traverses a BUFG; feedback is local to this MMCM.
  MMCME2_ADV #(.COMPENSATION("BUF_IN"),
      .CLKIN1_PERIOD(46.56084656),.DIVCLK_DIVIDE(1),.CLKFBOUT_MULT_F(36.0),
      .CLKOUT0_DIVIDE_F(12.0),.CLKOUT1_DIVIDE(36),.CLKOUT2_DIVIDE(12),
      .CLKOUT2_PHASE(MemoryPhase),.CLKOUT2_USE_FINE_PS("TRUE"),.CLKOUT3_DIVIDE(4)) mmcm (
      .CLKIN1(clk_source),.CLKIN2(1'b0),.CLKINSEL(1'b1),.CLKFBIN(fb_buf),.CLKFBOUT(fb),
      .CLKOUT0(fast_raw),.CLKOUT1(master_raw),.CLKOUT2(phase_raw),.LOCKED(locked),
      .RST(reset),.PWRDWN(1'b0),.PSCLK(service),.PSEN(ps_en),.PSINCDEC(ps_incdec),
      .DADDR(7'b0),.DCLK(1'b0),.DEN(1'b0),.DI(16'b0),.DWE(1'b0),
      .CLKFBOUTB(),.CLKOUT0B(),.CLKOUT1B(),.CLKOUT2B(),.CLKOUT3(ref_raw),.CLKOUT3B(),
      .CLKOUT4(),.CLKOUT5(),.CLKOUT6(),.PSDONE(ps_done),.DO(),.DRDY(),.CLKINSTOPPED(),.CLKFBSTOPPED());
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
