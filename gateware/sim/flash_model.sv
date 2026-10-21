`default_nettype none
`timescale 1ns / 1ps

// Упрощённая модель SPI-флеша: 06 WREN, 05 RDSR, D8 стирание 64К, 02 страница, 03 чтение, 9F ID.
// Хранит 64 КБ, адрес берётся по модулю 64 КБ. Время записи: WIP держится 2 мкс.
module flash_model (
    input  wire  sck,
    input  wire  cs_n,
    input  wire  mosi,
    output logic miso
);
  logic [7:0] mem[65536];
  logic [7:0] sh, cmd;
  logic [23:0] a;
  integer nbit, nbyte;
  logic wel = 0, wip = 0;
  logic [7:0] out;
  integer i;
  initial begin
    for (i = 0; i < 65536; i++) mem[i] = 8'hFF;
    miso = 1'bz;
  end
  always @(negedge cs_n) begin
    nbit = 0;
    nbyte = 0;
    out = 8'hFF;
  end
  always @(posedge cs_n) begin
    miso = 1'bz;
    if (cmd == 8'h06) wel = 1;
    if ((cmd == 8'hD8 || cmd == 8'h02) && nbyte >= 4) begin
      wel = 0;
      wip = 1;
      #2000 wip = 0;
    end
  end
  always @(posedge sck)
    if (!cs_n) begin
      sh = {sh[6:0], mosi};
      nbit = nbit + 1;
      if (nbit == 8) begin
        nbit = 0;
        if (nbyte == 0) cmd = sh;
        else if (nbyte <= 3) a = {a[15:0], sh};
        if (nbyte == 3 && cmd == 8'hD8 && wel) for (i = 0; i < 65536; i++) mem[i] = 8'hFF;
        if (nbyte >= 4 && cmd == 8'h02 && wel) begin
          mem[a[15:0]] = mem[a[15:0]] & sh;
          a[7:0] = a[7:0] + 1;  // запись в пределах страницы
        end
        nbyte = nbyte + 1;
        // следующий байт к выдаче
        case (cmd)
          8'h05: out = {6'd0, wel, wip};
          8'h9F: out = (nbyte == 1) ? 8'hC2 : (nbyte == 2) ? 8'h20 : 8'h18;
          8'h03:
          if (nbyte >= 4) begin
            out = mem[a[15:0]];
            a = a + 1;
          end
          default: out = 8'hFF;
        endcase
      end
    end
  always @(negedge sck)
    if (!cs_n) miso = out[7-nbit];
endmodule
