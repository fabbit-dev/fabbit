`default_nettype none

// Проверка HDMI на стенде: DVI 640×480@60, тестовые картинки сменяются каждые 4 с
// (полосы → сетка с рамкой → градиенты → белое). Светодиод мигает (~0,7 Гц), пока MMCM захвачен.
// Тракт тот же, что у оболочки: video_clocks → video_timing → video_pattern → hdmi_tx.
module hdmi_bars #(
    parameter bit Frac = 1'b1,          // 1: 25,1875 МГц (Vivado), 0: 25,000 МГц (openXC7)
    parameter logic [3:0] InvMask = '0  // перепутанные P/N по линиям, если прозвонка покажет
) (
    input  wire       clk,        // 25 МГц
    output wire       led,
    output wire       uart_tx,
    output wire [3:0] hdmi_p,
    output wire [3:0] hdmi_n
);
  import video_pkg::*;

  assign uart_tx = 1'b1;

  wire clk_pix, clk_5x, locked, rst;
  video_clocks #(.Frac(Frac)) u_clk (
      .clk_25m(clk), .clk_pix(clk_pix), .clk_5x(clk_5x), .locked(locked), .rst_pix(rst));

  // смена картинки раз в 240 кадров
  logic [7:0] frames = '0;
  logic [1:0] sel = '0;
  vpx_t tim, pat;

  video_timing u_tim (.clk(clk_pix), .rst(rst), .ce(1'b1), .px(tim));
  video_pattern u_pat (.clk(clk_pix), .ce(1'b1), .sel(sel), .px_in(tim), .px_out(pat));
  hdmi_tx #(.InvMask(InvMask)) u_tx (
      .clk_pix(clk_pix), .clk_5x(clk_5x), .px(pat), .pad_p(hdmi_p), .pad_n(hdmi_n));

  always_ff @(posedge clk_pix)
    if (tim.sof) begin
      frames <= (frames == 8'd239) ? '0 : frames + 1'b1;
      if (frames == 8'd239) sel <= sel + 1'b1;
    end

  logic [24:0] blink = '0;
  always_ff @(posedge clk_pix) blink <= blink + 1'b1;
  assign led = locked & blink[24];

endmodule
