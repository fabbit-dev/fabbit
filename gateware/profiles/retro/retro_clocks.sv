`default_nettype none

// NTSC master clocks shared by the MD and SNES wrappers, from the board 25 MHz.
// VCO=1181.25 MHz, MD=VCO/22=53.6931818 MHz (+0.127 ppm vs 53.693175),
// Z80=MD/2, SNES=VCO/55=21.4772727 MHz. All three clocks are phase related.
// SNES memory service needs a separate controller/PLL at 3x or 4x SNES master;
// this module does NOT invent an asynchronous exception or an SDRAM clock.
// Use reset_sync per domain on !locked; constrain generated clock relationships.
module retro_clocks (
    input  wire clk_25m,
    input  wire reset,
    output wire clk_md,
    output wire clk_z80,
    output wire clk_snes,
    output wire locked,
    output wire clk_memory
);
  wire fb, fb_buf, md_raw, z80_raw, snes_raw, memory_raw;
  MMCME2_ADV #(
      .BANDWIDTH("OPTIMIZED"),
      .CLKIN1_PERIOD(40.0),
      .DIVCLK_DIVIDE(1),
      .CLKFBOUT_MULT_F(47.25),
      .CLKOUT0_DIVIDE_F(22.0),
      .CLKOUT1_DIVIDE(44),
      .CLKOUT2_DIVIDE(55), .CLKOUT3_DIVIDE(22), .CLKOUT3_PHASE(38.863636)
  ) u_mmcm (
      .CLKIN1(clk_25m), .CLKIN2(1'b0), .CLKINSEL(1'b1), .CLKFBIN(fb_buf), .CLKFBOUT(fb),
      .CLKFBOUTB(), .CLKOUT0(md_raw), .CLKOUT0B(), .CLKOUT1(z80_raw), .CLKOUT1B(),
      .CLKOUT2(snes_raw), .CLKOUT2B(), .CLKOUT3(memory_raw), .CLKOUT3B(), .CLKOUT4(),
      .CLKOUT5(), .CLKOUT6(), .LOCKED(locked), .PWRDWN(1'b0), .RST(reset),
      .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0), .PSDONE(), .DADDR(7'd0),
      .DCLK(1'b0), .DEN(1'b0), .DI(16'd0), .DWE(1'b0), .DO(), .DRDY(),
      .CLKINSTOPPED(), .CLKFBSTOPPED());
  // Direct internal feedback (as profile_bus PLL); no global feedback deskew
  // assumption. Saves a global clock buffer for core gating/owner switching.
  assign fb_buf=fb;
  BUFG u_md (.I(md_raw), .O(clk_md));
  BUFG u_z80 (.I(z80_raw), .O(clk_z80));
  BUFG u_snes (.I(snes_raw), .O(clk_snes));
  BUFG u_memory (.I(memory_raw), .O(clk_memory));
endmodule
