`default_nettype none

// Оболочка профиля: отвечает ESP на ID ("FBPR", версия, режим 1, id профиля) и принимает TUNE.
// Остальные команды игнорирует. Вход в профиль: golden делает IPROG на слот; выход в меню —
// перезапуск питания модуля (ICAP в openXC7 не работает, docs/protocol.md).
module profile_shell #(
    parameter logic [15:0] ProfileId = 16'd0,
    parameter logic [ 7:0] Version = 8'd1
) (
    input  wire       clk,       // 100 МГц
    input  wire       esp_sck,
    input  wire       esp_cs_n,
    input  wire [3:0] d_in,
    output wire [3:0] d_out,
    output wire       d_oe,
    output wire       irq        // 1: профиль готов
);
  localparam logic [31:0] Key = "FBKY";

  logic [7:0] rd_start = 8'd16;
  logic       rd_fall = 1'b1;
  logic hdr_valid, wr_valid, rd_req, frame_end;
  logic [7:0] cmd, wr_data;
  logic [7:0] rd_data = 8'd0;
  logic [23:0] addr;
  qspi_slave u_q (
      .clk      (clk),
      .rd_start (rd_start),
      .rd_fall  (rd_fall),
      .sck      (esp_sck),
      .cs_n     (esp_cs_n),
      .d_in     (d_in),
      .d_out    (d_out),
      .d_oe     (d_oe),
      .hdr_valid(hdr_valid),
      .cmd      (cmd),
      .addr     (addr),
      .wr_valid (wr_valid),
      .wr_data  (wr_data),
      .rd_req   (rd_req),
      .rd_data  (rd_data),
      .frame_end(frame_end)
  );
  assign irq = 1'b1;

  logic [7:0] f_cmd = 8'd0;
  logic [23:0] f_addr = 24'd0;
  logic [31:0] f_key = 32'd0;
  logic [3:0] f_n = 4'd0;
  logic [2:0] rd_i = 3'd0;
  logic [63:0] id_word;
  assign id_word = {"FBPR", Version, 8'd1, ProfileId};

  always_ff @(posedge clk) begin
    if (hdr_valid) begin
      f_cmd  <= cmd;
      f_addr <= addr;
      f_n    <= 4'd0;
      rd_i   <= 3'd0;
    end
    if (rd_req && !hdr_valid) rd_i <= rd_i + 3'd1;
    rd_data <= (f_cmd == 8'h01) ? id_word[63-8*rd_i-:8] : 8'h00;
    if (wr_valid) begin
      f_key <= {f_key[23:0], wr_data};
      if (f_n != 4'hF) f_n <= f_n + 4'd1;
    end
    if (frame_end && f_cmd == 8'h07 && f_n == 4'd4 && f_key == Key) begin
      rd_start <= f_addr[7:0];
      rd_fall  <= f_addr[8];
    end
  end
endmodule
