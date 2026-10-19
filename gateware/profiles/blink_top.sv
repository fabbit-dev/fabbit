`default_nettype none

// Тестовый профиль: оболочка (ID для ESP) + мигалка. Pattern 0: 2 Гц, 1: тройная вспышка.
// UART ПЛИС раз в секунду: "P <id>".
module blink_top #(
    parameter logic [15:0] ProfileId = 16'd1,
    parameter bit          Pattern = 1'b0
) (
    input  wire       clk,       // 25 МГц, K4
    output wire       led,
    output wire       uart_tx,
    input  wire       esp_sck,
    input  wire       esp_cs_n,
    inout  wire [3:0] esp_d,
    output wire       esp_irq
);
  logic clk_fb, c100r, c100;
  PLLE2_BASE #(
      .CLKIN1_PERIOD (40.0),
      .DIVCLK_DIVIDE (1),
      .CLKFBOUT_MULT (40),
      .CLKOUT0_DIVIDE(10)
  ) u_pll (
      .CLKIN1(clk), .CLKFBIN(clk_fb), .CLKFBOUT(clk_fb), .CLKOUT0(c100r), .CLKOUT1(),
      .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(), .LOCKED(), .PWRDWN(1'b0), .RST(1'b0)
  );
  BUFG u_bufg (.I(c100r), .O(c100));

  logic [3:0] d_in, d_out;
  logic d_oe;
  for (genvar i = 0; i < 4; i++) begin : g_io
    IOBUF u_io (.IO(esp_d[i]), .I(d_out[i]), .T(~d_oe), .O(d_in[i]));
  end
  profile_shell #(
      .ProfileId(ProfileId)
  ) u_shell (
      .clk(c100), .esp_sck(esp_sck), .esp_cs_n(esp_cs_n), .d_in(d_in), .d_out(d_out), .d_oe(d_oe),
      .irq(esp_irq)
  );

  logic [26:0] t = 27'd0;
  always_ff @(posedge c100) t <= (t == 27'd99_999_999) ? 27'd0 : t + 27'd1;
  // 0: 2 Гц; 1: три вспышки по 50 мс в начале секунды
  assign led = Pattern ? (t < 27'd30_000_000 && t[22]) : t[24];

  logic pr_start = 1'b0, pr_busy;
  uart_hexline #(.Div(868)) u_pr (
      .clk(c100), .start(pr_start), .tag("P"), .value({16'd0, ProfileId}), .busy(pr_busy),
      .tx(uart_tx)
  );
  always_ff @(posedge c100) pr_start <= (t == 27'd0);
endmodule
