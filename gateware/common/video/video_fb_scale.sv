`default_nettype none

// Источник из буфера кадра ядра: ядро пишет пиксели SrcW×SrcH в своём такте, ступень читает их в
// такте пикселя и растягивает в Scale раз в окно с левым верхним углом (X0, Y0). Буфер — ram_sdp
// (BRAM, шаблон UG901): через границу тактов идут только данные памяти, не управление.
// Задержка ступени 2 такта. На выходе тот же поток vpx_t (цвет 0) плюс индекс пикселя и признак
// окна: цвет ставит следующая ступень (палитра ядра). Вне окна индекс 0, win = 0.
// Кадр ядра и кадр вывода не синхронизированы: при разной частоте кадров раз в несколько секунд
// через экран проходит строка разрыва.
module video_fb_scale
  import video_pkg::*;
#(
    parameter int DataW = 9,
    parameter int SrcW = 256,
    parameter int SrcH = 240,
    parameter int Scale = 2,
    parameter int X0 = 64,
    parameter int Y0 = 0,
    localparam int Xw = $clog2(SrcW),
    localparam int Yw = $clog2(SrcH)
) (
    // запись, такт ядра
    input  wire              wclk,
    input  wire              we,
    input  wire  [Xw-1:0]    wx,
    input  wire  [Yw-1:0]    wy,
    input  wire  [DataW-1:0] wdata,
    // чтение, такт пикселя
    input  wire              clk,
    input  vpx_t             px_in,
    output vpx_t             px_out,
    output logic [DataW-1:0] idx,
    output logic             win
);
  localparam int Depth = 1 << (Xw + Yw);

  // окно и адрес в источнике для текущего пикселя
  wire [11:0] dx = px_in.x - 12'(X0);
  wire [11:0] dy = px_in.y - 12'(Y0);
  wire in_win = px_in.de && px_in.x >= 12'(X0) && px_in.x < 12'(X0 + SrcW * Scale) &&
                px_in.y >= 12'(Y0) && px_in.y < 12'(Y0 + SrcH * Scale);
  wire [Xw-1:0] sx = Xw'(dx / 12'(Scale));
  wire [Yw-1:0] sy = Yw'(dy / 12'(Scale));

  wire [DataW-1:0] rdata;
  ram_sdp #(.Width(DataW), .Depth(Depth)) u_fb (
      .wclk(wclk), .we(we), .waddr({wy, wx}), .wdata(wdata),
      .rclk(clk), .re(1'b1), .raddr({sy, sx}), .rdata(rdata));

  vpx_t p1;
  logic w1 = 1'b0;
  always_ff @(posedge clk) begin
    p1     <= vpx_rgb(px_in, 8'd0, 8'd0, 8'd0);
    w1     <= in_win;
    px_out <= p1;
    win    <= w1;
    idx    <= w1 ? rdata : '0;
  end

endmodule
