`default_nettype none
`timescale 1ns / 1ps

// nes_system целиком на модели SDRAM: ROM (+rom=файл.hex, байт на строку) идёт потоком в загрузчик,
// ядро работает +frames=N кадров, кадр 256×240 пишется в +ppm=файл и печатается его CRC-32.
// Проверки: ROM загружен без ошибки, кадр не пустой (больше одного цвета), в SDRAM нет нарушений.
// Кнопки: +press=08 +press_at=10 +press_len=6 (nes15: Start на 10-м кадре → поле 4×4 к 40-му).
module tb_nes;
  import nes_palette_pkg::*;

  localparam time Tf = 15556ps;  // fclk 64,286 МГц, nclk = fclk / 3
  logic fclk = 0, nclk = 0, sdram_clk = 0;
  always #(Tf / 2) fclk = ~fclk;
  initial begin
    #(14500ps);  // фаза такта микросхемы в окне модели (tb_sdram)
    forever #(Tf / 2) sdram_clk = ~sdram_clk;
  end
  int div = 0;
  always @(posedge fclk) begin
    div <= (div == 2) ? 0 : div + 1;
    if (div == 0) nclk <= 1;
    if (div == 1) nclk <= 0;
  end

  // ROM
  logic [7:0] rom [1 << 20];
  int rom_len = 0, rom_pos = 0;
  logic rst = 1, load_go = 0;
  wire rom_ready, loading, done, fail, reset_nes, fb_we;
  wire rom_valid = loading && rom_pos < rom_len;
  wire [7:0] fb_x, fb_y;
  wire [8:0] fb_d, scanline;
  wire sd_clk, ras_n, cas_n, we_n;
  wire [10:0] sd_a;
  wire [1:0] sd_ba;
  wire [31:0] sd_dq;

  always @(posedge nclk) if (rom_ready) rom_pos <= rom_pos + 1;

  nes_system dut (
      .nclk(nclk), .fclk(fclk), .sdram_clk_in(sdram_clk), .rst(rst), .load_go(load_go),
      .reset_go(1'b0), .rom_valid(rom_valid), .rom_ready(rom_ready), .rom_data(rom[rom_pos]),
      .joy(joy), .loading(loading), .loader_done(done), .loader_fail(fail),
      .reset_nes(reset_nes), .fb_we(fb_we), .fb_x(fb_x), .fb_y(fb_y), .fb_d(fb_d), .sample(),
      .scanline(scanline), .sdram_clk(sd_clk), .sdram_a(sd_a), .sdram_ba(sd_ba),
      .sdram_ras_n(ras_n), .sdram_cas_n(cas_n), .sdram_we_n(we_n), .sdram_dq(sd_dq));

  sdram_model u_sd (
      .clk(sd_clk), .cke(1'b1), .cs_n(1'b0), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
      .ba(sd_ba), .a(sd_a), .dqm(4'b0000), .dq(sd_dq));

  // кнопки: +press=биты +press_at=кадр +press_len=кадров (как CSR 5 профиля)
  logic [7:0] joy = 8'h00;
  int frames = 0;
  int press = 0, press_at = 0, press_len = 0;
  initial begin
    void'($value$plusargs("press=%h", press));
    void'($value$plusargs("press_at=%d", press_at));
    void'($value$plusargs("press_len=%d", press_len));
  end
  always @(posedge nclk)
    joy <= (frames >= press_at && frames < press_at + press_len) ? 8'(press) : 8'h00;

  // кадр
  logic [8:0] fb [256 * 240];
  always @(posedge nclk) if (fb_we) fb[{fb_y, fb_x}] = fb_d;
  logic [8:0] line_d = 0;
  always @(posedge nclk) begin
    line_d <= scanline;
    if (!reset_nes && scanline == 9'd240 && line_d == 9'd239) frames <= frames + 1;
  end

  int errors = 0;
  task automatic check(input bit ok, input string what);
    if (ok) $display("ok   %s", what);
    else begin
      $display("FAIL %s", what);
      errors++;
    end
  endtask

  function automatic logic [31:0] crc32(input logic [31:0] crc, input logic [7:0] b);
    crc = crc ^ 32'(b);
    for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (32'hEDB88320 & -(crc & 1));
    return crc;
  endfunction

  initial begin
    string rom_file, ppm_file;
    int want_frames, fd, colors;
    logic [31:0] crc;
    bit seen [512];
    if (!$value$plusargs("rom=%s", rom_file)) rom_file = "profiles/nes/core/src/roms/nes15.hex";
    if (!$value$plusargs("frames=%d", want_frames)) want_frames = 4;
    if (!$value$plusargs("ppm=%s", ppm_file)) ppm_file = "build/tb_nes.ppm";
    fd = $fopen(rom_file, "r");
    if (fd == 0) $fatal(1, "нет файла %s", rom_file);
    while (rom_len < (1 << 20) && $fscanf(fd, "%h", rom[rom_len]) == 1) rom_len++;
    $fclose(fd);
    $display("ROM %s: %0d байт", rom_file, rom_len);

    repeat (10) @(posedge nclk);
    rst = 0;
    wait (!dut.u_mem.busy);  // SDRAM прошла инициализацию (200 мкс)
    @(posedge nclk) load_go = 1;
    @(posedge nclk) load_go = 0;
    wait (!loading);
    // загрузчик берёт заголовок 16 Б + PRG (16 КБ × ines[4]) + CHR (8 КБ × ines[5]); хвост файла
    // (у nes15 4 КБ после CHR) ему не нужен
    check(done && !fail && rom_pos == 16 + 16384 * rom[4] + 8192 * rom[5],
          $sformatf("ROM загружен: %0d байт (PRG %0d × 16 КБ, CHR %0d × 8 КБ), ошибка %b", rom_pos,
                    rom[4], rom[5], fail));
    wait (frames == want_frames);
    // сам кадр
    crc = '1;
    colors = 0;
    foreach (fb[i]) begin
      crc = crc32(crc, fb[i][7:0]);
      crc = crc32(crc, {7'd0, fb[i][8]});
      if (!seen[fb[i]]) begin
        seen[fb[i]] = 1;
        colors++;
      end
    end
    fd = $fopen(ppm_file, "w");
    $fwrite(fd, "P3\n256 240\n255\n");
    foreach (fb[i]) begin
      logic [23:0] c;
      c = nes_rgb(fb[i]);
      $fwrite(fd, "%0d %0d %0d\n", c[23:16], c[15:8], c[7:0]);
    end
    $fclose(fd);
    $display("кадр %0d: CRC %08h, цветов %0d, картинка %s", frames, ~crc, colors, ppm_file);
    check(colors > 1, $sformatf("кадр не пустой: %0d цветов", colors));
    check(u_sd.errors == 0, $sformatf("нарушений SDRAM: %0d", u_sd.errors));
    if (errors) $fatal(1, "ОШИБОК %0d", errors);
    else $display("ВСЁ OK");
    $finish;
  end

endmodule
