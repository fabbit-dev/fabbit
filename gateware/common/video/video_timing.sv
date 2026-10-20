`default_nettype none

// Генератор развёртки: начало тракта. Выдаёт поток vpx_t с координатами и синхро,
// цвет нулевой (его ставит источник). Задержка 1 такт, ce = пиксель (на 1 такт clk).
// Одна развёртка на оболочку: от неё питаются HDMI и LCD прибора.
module video_timing
  import video_pkg::*;
#(
    parameter vmode_t Mode = Vmode640x480
) (
    input  wire  clk,
    input  wire  rst,
    input  wire  ce,
    output vpx_t px
);
  localparam int HTotal = int'(Mode.h_active) + int'(Mode.h_front) + int'(Mode.h_sync) +
                          int'(Mode.h_back);
  localparam int VTotal = int'(Mode.v_active) + int'(Mode.v_front) + int'(Mode.v_sync) +
                          int'(Mode.v_back);
  localparam int HSync0 = int'(Mode.h_active) + int'(Mode.h_front);
  localparam int VSync0 = int'(Mode.v_active) + int'(Mode.v_front);

  logic [11:0] x, y;

  always_ff @(posedge clk)
    if (rst) begin
      x  <= '0;
      y  <= '0;
      px <= '0;
    end else if (ce) begin
      if (x == 12'(HTotal - 1)) begin
        x <= '0;
        y <= (y == 12'(VTotal - 1)) ? '0 : y + 1'b1;
      end else begin
        x <= x + 1'b1;
      end
      px     <= '0;
      px.x   <= x;
      px.y   <= y;
      px.de  <= (x < 12'(Mode.h_active)) && (y < 12'(Mode.v_active));
      px.hs  <= Mode.h_pol ~^ ((x >= 12'(HSync0)) && (x < 12'(HSync0 + int'(Mode.h_sync))));
      px.vs  <= Mode.v_pol ~^ ((y >= 12'(VSync0)) && (y < 12'(VSync0 + int'(Mode.v_sync))));
      px.sof <= (x == '0) && (y == '0);
    end

endmodule
