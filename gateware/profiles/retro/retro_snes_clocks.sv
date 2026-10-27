// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// Source = retro_clocks SNES output, 21.4772727MHz. VCO=source*40;
// service /10, master /40 and forwarded SDRAM /10 with 2ns nominal shift.
// One MMCM gives integer 4:1 related clocks. Phase is a simulation starting
// point, NOT calibrated SDRAM board timing.
module retro_snes_clocks (
    input wire clk_source, reset,
    output wire service, master, memory_clock, locked,
    output wire master_ce
);
  wire fb,fb_buf,fast_raw,master_raw,phase_raw;
  // clk_source already traverses a BUFG; feedback is local to this MMCM.
  MMCME2_ADV #(.COMPENSATION("BUF_IN"),
      .CLKIN1_PERIOD(46.56084656),.DIVCLK_DIVIDE(1),.CLKFBOUT_MULT_F(40.0),
      .CLKOUT0_DIVIDE_F(10.0),.CLKOUT1_DIVIDE(40),.CLKOUT2_DIVIDE(10),
      .CLKOUT2_PHASE(63.0)) mmcm (
      .CLKIN1(clk_source),.CLKIN2(1'b0),.CLKINSEL(1'b1),.CLKFBIN(fb_buf),.CLKFBOUT(fb),
      .CLKOUT0(fast_raw),.CLKOUT1(master_raw),.CLKOUT2(phase_raw),.LOCKED(locked),
      .RST(reset),.PWRDWN(1'b0),.PSCLK(1'b0),.PSEN(1'b0),.PSINCDEC(1'b0),
      .DADDR(7'b0),.DCLK(1'b0),.DEN(1'b0),.DI(16'b0),.DWE(1'b0),
      .CLKFBOUTB(),.CLKOUT0B(),.CLKOUT1B(),.CLKOUT2B(),.CLKOUT3(),.CLKOUT3B(),
      .CLKOUT4(),.CLKOUT5(),.CLKOUT6(),.PSDONE(),.DO(),.DRDY(),.CLKINSTOPPED(),.CLKFBSTOPPED());
  // Match BUF_IN's required buffered feedback without another global BUFG.
  BUFH feedback_buffer (.I(fb),.O(fb_buf));
  BUFG fast_buffer (.I(fast_raw),.O(service));
  BUFG master_buffer (.I(master_raw),.O(master));
  BUFG phase_buffer (.I(phase_raw),.O(memory_clock));
  // free_master is low throughout the two service cycles before its next edge.
  // Observe falling edge then count to the coincident rising edge. The phase
  // counter is reanchored on EVERY falling edge rather than relying on power-up.
  logic master_delayed=0;
  logic [1:0] phase=3;
  always_ff @(negedge service) begin
    master_delayed<=master;
    if (!locked) phase<=3;
    else if (master_delayed && !master) phase<=2;
    else phase<=phase+1'b1;
  end
  assign master_ce=phase==3;
endmodule
`default_nettype wire
