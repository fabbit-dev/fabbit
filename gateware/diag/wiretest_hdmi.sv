`default_nettype none

// Прозвонка ножек HDMI без монитора: на каждой из 8 ножек свой меандр, ЛА на площадках
// C6..C13 девборды (сторона ПЛИС). Частоты: hdmi_p[l] = (2l+1) кГц, hdmi_n[l] = (2l+2) кГц:
//   D0+ 1, D0− 2, D1+ 3, D1− 4, D2+ 5, D2− 6, CLK+ 7, CLK− 8 кГц.
// Монитор не подключать: на разъёме нет защиты, а меандр не TMDS.
module wiretest_hdmi (
    input  wire       clk,       // 25 МГц
    output wire       led,
    output wire       uart_tx,
    output wire [3:0] hdmi_p,
    output wire [3:0] hdmi_n
);
  assign uart_tx = 1'b1;

  logic [7:0] sq = '0;
  for (genvar k = 0; k < 8; k++) begin : g_sq
    localparam int Half = 25_000_000 / (2 * 1000 * (k + 1));  // полпериода (k+1) кГц
    logic [13:0] cnt = '0;
    always_ff @(posedge clk)
      if (cnt == 14'(Half - 1)) begin
        cnt   <= '0;
        sq[k] <= ~sq[k];
      end else begin
        cnt <= cnt + 1'b1;
      end
  end

  for (genvar l = 0; l < 4; l++) begin : g_pad
    assign hdmi_p[l] = sq[2*l];
    assign hdmi_n[l] = sq[2*l+1];
  end

  logic [24:0] blink = '0;
  always_ff @(posedge clk) blink <= blink + 1'b1;
  assign led = blink[24];

endmodule
