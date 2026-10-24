`default_nettype none

// Пад Fabbit (RetroPad, docs/bus-protocol.md) → байт контроллера NES в домене ядра.
//   NES A = A (правая кнопка ромба), NES B = B (нижняя), турбо A = X (верхняя), турбо B = Y (левая),
//   Select = Select, Start = Start. Турбо: 10 Гц, полупериод 3 кадра (по началу кадра frame).
//   Противоположные направления вместе (вверх и вниз, влево и вправо) снимаются: на настоящей
//   крестовине так нажать нельзя, часть игр от этого ломается.
// Выход: A, B, Select, Start, Вверх, Вниз, Влево, Вправо = биты 0..7 (порядок регистра 4021).
module nes_pad (
    input  wire        clk,
    input  wire        frame,     // импульс: начало кадра
    input  wire [15:0] pad,
    output logic [7:0] joy
);
  localparam int Up = 0, Down = 1, Left = 2, Right = 3, A = 4, B = 5, X = 6, Y = 7;
  localparam int Select = 14, Start = 15;
  localparam logic [1:0] TurboHalf = 2'd2;  // 0..2: три кадра

  logic [1:0] fcnt = '0;
  logic turbo = 1'b0;
  always_ff @(posedge clk)
    if (frame) begin
      if (fcnt == TurboHalf) begin
        fcnt  <= '0;
        turbo <= ~turbo;
      end else fcnt <= fcnt + 2'd1;
    end

  wire up = pad[Up] && !pad[Down];
  wire down = pad[Down] && !pad[Up];
  wire left = pad[Left] && !pad[Right];
  wire right = pad[Right] && !pad[Left];

  always_ff @(posedge clk)
    joy <= {right, left, down, up, pad[Start], pad[Select],
            pad[B] || (pad[Y] && turbo), pad[A] || (pad[X] && turbo)};

endmodule
