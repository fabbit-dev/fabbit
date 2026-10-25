`default_nettype none

// Такты видео из 25 МГц модуля: пиксель и 5× для сериализатора TMDS, оба с одного MMCM.
//   Frac = 1: M = 50,375, D = 2 → 25,1875 МГц (+0,05 % к 25,175; 59,99 Гц). Только Vivado:
//             дробный MMCM в openXC7 даёт битстрим, отличный от Vivado (POWER_REG и др.).
//   Frac = 0: M = 30, D = 1 → 25,000 МГц (−0,7 %; 59,52 Гц). Собирается и openXC7.
// rst_pix держится до захвата MMCM и ещё 15 тактов пикселя.
module video_clocks #(
    parameter bit Frac = 1'b1
) (
    input  wire  clk_25m,
    output wire  clk_pix,
    output wire  clk_5x,
    output wire  locked,
    output wire  rst_pix
);
  localparam real Mult = Frac ? 50.375 : 30.0;
  localparam int Div = Frac ? 2 : 1;
  localparam real DivPix = Frac ? 25.0 : 30.0;
  localparam int Div5x = Frac ? 5 : 6;

  wire fb, fb_buf, pix_raw, x5_raw;

  MMCME2_BASE #(
      .CLKIN1_PERIOD(40.0), .DIVCLK_DIVIDE(Div), .CLKFBOUT_MULT_F(Mult),
      .CLKOUT0_DIVIDE_F(DivPix), .CLKOUT1_DIVIDE(Div5x)
  ) u_mmcm (
      .CLKIN1(clk_25m), .CLKFBIN(fb_buf), .CLKFBOUT(fb), .CLKFBOUTB(), .RST(1'b0), .PWRDWN(1'b0),
      .CLKOUT0(pix_raw), .CLKOUT1(x5_raw), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
      .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .LOCKED(locked)
  );

  BUFG u_bfb (.I(fb), .O(fb_buf));
  BUFG u_bpix (.I(pix_raw), .O(clk_pix));
  BUFG u_b5x (.I(x5_raw), .O(clk_5x));

  logic [3:0] hold = '1;
  always_ff @(posedge clk_pix or negedge locked)
    if (!locked) hold <= '1;
    else if (hold != 0) hold <= hold - 1'b1;
  assign rst_pix = hold != 0;

endmodule
