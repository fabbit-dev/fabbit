`default_nettype none

// Слово в другой домен по рукопожатию-переключателю (Cummings SNUG 2008, «MCP formulation»):
// источник защёлкивает слово и меняет бит tgl, приёмник ловит смену через sync_bit и берёт слово,
// которое к этому моменту стоит не меньше двух тактов приёмника. Условие: stb не чаще раза
// в 4 такта dclk (у шины ESP кадр PAD длится ≥ 1,6 мкс, у ядра NES такт 47 нс).
// В XDC: set_max_delay -datapath_only на путь word_q → q (не дольше периода dclk).
module cdc_word #(
    parameter int Width = 32
) (
    input  wire             sclk,
    input  wire             stb,     // импульс: d новое
    input  wire [Width-1:0] d,
    input  wire             dclk,
    output logic [Width-1:0] q = '0,
    output logic            q_stb = 1'b0
);
  logic [Width-1:0] word_q = '0;
  logic tgl = 1'b0;
  always_ff @(posedge sclk)
    if (stb) begin
      word_q <= d;
      tgl    <= ~tgl;
    end

  wire tgl_s;
  logic tgl_d = 1'b0;
  sync_bit u_s (.clk(dclk), .d(tgl), .q(tgl_s));
  always_ff @(posedge dclk) begin
    tgl_d <= tgl_s;
    q_stb <= tgl_s ^ tgl_d;
    if (tgl_s ^ tgl_d) q <= word_q;
  end

endmodule
