`default_nettype none

// Такты ядра NES и SDRAM из 25 МГц модуля, один MMCM (целые коэффициенты: собирается и openXC7;
// множитель MMCM ≤ 64, поэтому точнее 21,477 МГц без дробного делителя не выйти):
//   VCO = 25 × 36 = 900 МГц
//   clk       = VCO / 42 = 21,429 МГц  (NTSC 21,477, −0,23 %: кадр 59,96 Гц): ядро NES, CE внутри
//   fclk      = VCO / 14 = 64,286 МГц  = 3 × clk, синфазно: контроллер SDRAM (sdram_nes)
//   sdram_clk = VCO / 14, сдвиг SdramPhase° + динамический (PSEN, шаг VCO/56 = 19,8 пс,
//               784 шага на период): такт микросхемы, наружу через ODDR.
// SdramPhase = середина окна, найденного diag/sdram_eye на стенде 2026-10-21: окно 13,3 нс из 15,56 нс
// (180° + 215 шагов ≈ 279°), 154 прохода по 1M слов без ошибок.
module nes_clocks #(
    parameter real SdramPhase = 279.0,
    // Preserve the direct clock-pin topology for standalone NES/diagnostics.
    parameter string Compensation = "ZHOLD"
) (
    input  wire clk_25m,
    input  wire psclk,      // такт интерфейса сдвига фазы (шина ESP, 100 МГц)
    input  wire psen,       // импульс: сдвиг на один шаг
    input  wire psincdec,   // 1: позже, 0: раньше
    output wire psdone,     // импульс: сдвиг сделан (через 12 тактов psclk)
    output wire clk,
    output wire fclk,
    output wire sdram_clk,
    output wire locked
);
  wire fb, fb_buf, c0, c1, c2;

  MMCME2_ADV #(
      .BANDWIDTH("OPTIMIZED"),
      .COMPENSATION(Compensation),
      .CLKIN1_PERIOD(40.0),
      .DIVCLK_DIVIDE(1),
      .CLKFBOUT_MULT_F(36.0),
      .CLKOUT0_DIVIDE_F(42.0),
      .CLKOUT1_DIVIDE(14),
      .CLKOUT2_DIVIDE(14),
      .CLKOUT2_PHASE(SdramPhase),
      .CLKOUT2_USE_FINE_PS("TRUE")
  ) u_mmcm (
      .CLKIN1(clk_25m), .CLKIN2(1'b0), .CLKINSEL(1'b1), .CLKFBIN(fb_buf), .CLKFBOUT(fb),
      .CLKFBOUTB(), .CLKOUT0(c0), .CLKOUT0B(), .CLKOUT1(c1), .CLKOUT1B(), .CLKOUT2(c2),
      .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
      .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0),
      .PSCLK(psclk), .PSEN(psen), .PSINCDEC(psincdec), .PSDONE(psdone),
      .DADDR(7'd0), .DCLK(1'b0), .DEN(1'b0), .DI(16'd0), .DWE(1'b0), .DO(), .DRDY(),
      .CLKINSTOPPED(), .CLKFBSTOPPED()
  );

  BUFG u_bfb (.I(fb), .O(fb_buf));
  BUFG u_b0 (.I(c0), .O(clk));
  BUFG u_b1 (.I(c1), .O(fclk));
  BUFG u_b2 (.I(c2), .O(sdram_clk));

endmodule
