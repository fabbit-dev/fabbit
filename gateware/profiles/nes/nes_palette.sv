`default_nettype none

// Ступень видеотракта после video_fb_scale: индекс PPU → RGB (nes_palette_pkg). Вне окна —
// чёрная рамка. Задержка 1 такт.
module nes_palette
  import video_pkg::*;
  import nes_palette_pkg::*;
(
    input  wire        clk,
    input  vpx_t       px_in,
    input  wire  [8:0] idx,    // {emphasis[2:0], color[5:0]}
    input  wire        win,
    output vpx_t       px_out
);
  wire [23:0] c = win ? nes_rgb(idx) : 24'h000000;

  always_ff @(posedge clk) px_out <= vpx_rgb(px_in, c[23:16], c[15:8], c[7:0]);

endmodule
