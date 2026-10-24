`default_nettype none

// Плоскость меню 640×480, 4 бита на пиксель, палитра 16 × RGB888. Рисует супервизор по шине,
// плоскость только хранит и показывает. Пока плоскость не включена (OSD_CTRL), ступень выдаёт
// заставку: логотип из brand-kit (80×19 клеток по 5 пикселей), как boot-640x480 бренд-кита.
//
// Команды шины (кадр «команда 8 + адрес 24», docs/bus-protocol.md):
//   40 OSD_RECT  addr = {y[11:0], x[11:0]}, x чётный; данные: w(2) h(2) BE, w чётная, затем
//                пиксели построчно, байт = 2 пикселя, старший нибл левее. Лишние байты отброшены.
//   41 OSD_FILL  addr как у 40; данные: w(2) h(2) цвет(1); байт цвета = 2 пикселя (узор).
//                Заливка идёт после CS#↑ по байту за такт (w/2 · h тактов 100 МГц), busy = 1
//                до конца: полный экран 1,54 мс.
//   42 OSD_PAL   addr[3:0] = первый индекс; данные: R G B на индекс, индекс растёт.
//   43 OSD_CTRL  addr[0] = 1: показывать плоскость, 0: заставку. Только с ключом: ровно 4 байта
//                "FBKY", иначе мусор на шине при перезагрузке ESP прячет заставку.
// Пиксели за краем экрана отброшены. Кадр 40/41, начатый при busy = 1, отброшен целиком.
//
// Память: 153 600 байт (38 RAMB36), запись в такте шины, чтение в такте пикселя.
// Палитра и CTRL меняются редко и идут в такт пикселя без синхронизатора: смена даёт не больше
// одного кадра с частью старых цветов. frames: счётчик кадров видео в такте шины.
// Задержка ступени 2 такта пикселя.
module osd_plane
  import video_pkg::*;
(
    // шина, 100 МГц
    input  wire         clk,
    input  wire         hdr_valid,
    input  wire  [ 7:0] cmd,
    input  wire  [23:0] addr,
    input  wire         wr_valid,
    input  wire  [ 7:0] wr_data,
    input  wire         frame_end,
    output wire         busy,
    output wire         shown,          // 1: на экране плоскость, 0: заставка
    output logic [15:0] frames = '0,
    // видео
    input  wire         clk_pix,
    input  vpx_t        px_in,
    output vpx_t        px_out
);
  localparam logic [7:0] CmdRect = 8'h40, CmdFill = 8'h41, CmdPal = 8'h42, CmdCtrl = 8'h43;
  localparam int W = 640, H = 480, Row = W / 2, Depth = Row * H;
  localparam int Aw = $clog2(Depth);

  // ---------------- запись ----------------
  logic [ 7:0] f_cmd = '0;
  logic [11:0] x0 = '0, y0 = '0;
  logic [ 2:0] n = '0;  // принято байт заголовка (насыщается на 5)
  logic [15:0] w = '0, h = '0;
  logic [11:0] cx = '0, cy = '0;  // текущий пиксель
  logic [Aw-1:0] row_base = '0, ptr = '0;
  logic [ 7:0] fill_c = '0;
  logic        filling = 1'b0, drop = 1'b0, ctrl_on = 1'b0;
  logic        we = 1'b0;
  logic [Aw-1:0] waddr = '0;
  logic [ 7:0] wdata = '0;
  logic [ 3:0] pal_i = '0;
  logic [ 1:0] pal_n = '0;
  logic [15:0] pal_rg = '0;
  logic [23:0] pal [16];
  logic        show = 1'b0;
  logic [31:0] key = '0;
  localparam logic [31:0] Key = "FBKY";

  initial for (int i = 0; i < 16; i++) pal[i] = {3{8'(i * 17)}};

  wire in_screen = cx < 12'(W) && cy < 12'(H);
  wire last_col = cx + 12'd2 >= x0 + w[11:0];

  // следующий байт прямоугольника: вправо, в конце строки на начало следующей
  task automatic step();
    if (last_col) begin
      cx       <= x0;
      cy       <= cy + 1'b1;
      row_base <= row_base + Aw'(Row);
      ptr      <= row_base + Aw'(Row);
    end else begin
      cx  <= cx + 12'd2;
      ptr <= ptr + 1'b1;
    end
  endtask

  wire rows_left = cy < y0 + h[11:0];

  always_ff @(posedge clk) begin
    we <= 1'b0;
    if (hdr_valid) begin
      f_cmd <= cmd;
      pal_i <= addr[3:0];
      ctrl_on <= addr[0];
      pal_n <= '0;
      n     <= '0;
      drop  <= filling;  // кадр 40/41, начатый во время заливки, отброшен целиком
      if (!filling) begin  // x0, y0 нужны заливке до конца
        x0 <= {addr[11:1], 1'b0};
        y0 <= addr[23:12];
      end
    end

    if (wr_valid && !drop && (f_cmd == CmdRect || f_cmd == CmdFill)) begin
      if (n != 3'd5) n <= n + 1'b1;
      unique case (n)
        3'd0: w[15:8] <= wr_data;
        3'd1: w[7:0] <= wr_data;
        3'd2: h[15:8] <= wr_data;
        3'd3: begin
          h[7:0]   <= wr_data;
          cx       <= x0;
          cy       <= y0;
          row_base <= Aw'(y0) * Aw'(Row) + Aw'(x0[11:1]);
          ptr      <= Aw'(y0) * Aw'(Row) + Aw'(x0[11:1]);
        end
        default: begin
          if (f_cmd == CmdFill) begin
            if (n == 3'd4) fill_c <= wr_data;
          end else if (rows_left && w != 0) begin
            we    <= in_screen;
            waddr <= ptr;
            wdata <= wr_data;
            step();
          end
        end
      endcase
    end

    if (wr_valid && f_cmd == CmdCtrl) begin
      key <= {key[23:0], wr_data};
      if (n != 3'd5) n <= n + 1'b1;
    end

    if (wr_valid && f_cmd == CmdPal) begin
      pal_n <= (pal_n == 2'd2) ? 2'd0 : pal_n + 1'b1;
      if (pal_n == 2'd0) pal_rg[15:8] <= wr_data;
      if (pal_n == 2'd1) pal_rg[7:0] <= wr_data;
      if (pal_n == 2'd2) begin
        pal[pal_i] <= {pal_rg, wr_data};
        pal_i      <= pal_i + 1'b1;
      end
    end

    if (frame_end && f_cmd == CmdCtrl && n == 3'd4 && key == Key) show <= ctrl_on;
    if (frame_end && !drop && f_cmd == CmdFill && n == 3'd5 && w != 0 && h != 0) filling <= 1'b1;
    if (frame_end) f_cmd <= '0;

    if (filling) begin
      if (!rows_left) filling <= 1'b0;
      else begin
        we    <= in_screen;
        waddr <= ptr;
        wdata <= fill_c;
        step();
      end
    end
  end

  assign busy = filling;
  assign shown = show;

  // ---------------- чтение и вывод ----------------
  // адрес байта пикселя (x, y): y·320 + x/2
  wire [Aw-1:0] raddr = Aw'({px_in.y, 8'd0}) + Aw'({px_in.y, 6'd0}) + Aw'(px_in.x[11:1]);
  wire [7:0] rdata;
  ram_sdp #(.Width(8), .Depth(Depth)) u_mem (
      .wclk(clk), .we(we), .waddr(waddr), .wdata(wdata),
      .rclk(clk_pix), .re(1'b1), .raddr(raddr), .rdata(rdata));

  // заставка: логотип 80×19 клеток, клетка 5×5, левый верхний угол (120, 182)
  localparam int LX = 120, LY = 182, Cell = 5, LW = 80, LH = 19;
  localparam logic [LW-1:0] Logo [LH] = '{
      80'b01110000000111000000001111111111000000000000111000000000111000000000111000000000,
      80'b01110000000111000000001111111111000000000000111000000000111000000000111000000000,
      80'b01111000011111000000001111111111000000000000111000000000111000000000111000111000,
      80'b01111000011111000000001110000000000000000000111000000000111000000000000000111000,
      80'b01111000011111000000001110000000000000000000111000000000111000000000000000111000,
      80'b01111000011111000000001110000000000000000000111000000000111000000000000000111000,
      80'b01111001111100000000001111111100011111111000111111111000111111111000111001111111,
      80'b01111001111100000000001111111100111111111100111111111100111111111100111001111111,
      80'b00111111111100000000001111111100111111111100111111111100111111111100111001111111,
      80'b00111111111111000000001110000000000000011100111000011100111000011100111000111000,
      80'b00111111111111000000001110000000011111111100111000011100111000011100111000111000,
      80'b11111111111111110000001110000000111111111100111000011100111000011100111000111000,
      80'b11100111111001110000001110000000111111111100111000011100111000011100111000111000,
      80'b11100111111001110000001110000000111000011100111000011100111000011100111000111000,
      80'b11111111111111110000001110000000111000011100111000011100111000011100111000111000,
      80'b11111110011111110000001110000000111000011100111000011100111000011100111000111000,
      80'b11111110011111110000001110000000111111111100111111111100111111111100111000111111,
      80'b00111111111111000000001110000000111111111100111111111100111111111100111000111111,
      80'b00111111111111000000001110000000011111111100111111111000111111111000111000011111};
  wire [11:0] lx = px_in.x - 12'(LX), ly = px_in.y - 12'(LY);
  wire in_logo = px_in.x >= 12'(LX) && px_in.x < 12'(LX + LW * Cell) &&
                 px_in.y >= 12'(LY) && px_in.y < 12'(LY + LH * Cell);
  wire [6:0] lc = 7'(lx / 12'(Cell));
  wire [4:0] lr = 5'(ly / 12'(Cell));
  wire logo_bit = in_logo && Logo[lr][7'(LW - 1) - lc];

  vpx_t p1;
  logic ink1 = 1'b0, show1 = 1'b0;
  always_ff @(posedge clk_pix) begin
    p1    <= px_in;
    ink1  <= logo_bit;
    show1 <= show;
  end

  wire [3:0] nib = p1.x[0] ? rdata[3:0] : rdata[7:4];
  wire [23:0] c = !p1.de ? 24'h000000 : show1 ? pal[nib] : (ink1 ? 24'hFFFFFF : 24'h000000);
  always_ff @(posedge clk_pix) px_out <= vpx_rgb(p1, c[23:16], c[15:8], c[7:0]);

  // ---------------- счётчик кадров в такте шины ----------------
  logic sof_tgl = 1'b0;
  always_ff @(posedge clk_pix) if (px_in.sof) sof_tgl <= ~sof_tgl;
  wire sof_s;
  logic sof_d = 1'b0;
  sync_bit u_sof (.clk(clk), .d(sof_tgl), .q(sof_s));
  always_ff @(posedge clk) begin
    sof_d <= sof_s;
    if (sof_s ^ sof_d) frames <= frames + 1'b1;
  end

endmodule
