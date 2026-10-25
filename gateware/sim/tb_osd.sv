`default_nettype none
`timescale 1ns / 1ps

// osd_plane глазами ESP: шина quad SPI 10 МГц → qspi_slave → osd_plane → кадр 640×480.
// Заставка (логотип до OSD_CTRL), палитра, заливка, прямоугольник с краем экрана, кадр во время
// заливки, счётчик кадров. Каждый кадр сверяется с эталоном, который тест строит сам.
// Кадр: build/tb_osd.ppm.
module tb_osd;
  import video_pkg::*;

  logic clk = 0, clk_pix = 0, rst = 1;
  always #5 clk = ~clk;            // шина 100 МГц
  always #19.85 clk_pix = ~clk_pix;  // 25,19 МГц
  initial #300ns rst = 0;

  logic sck = 0, cs_n = 1;
  logic [3:0] m_out = 0;
  wire hdr_valid, wr_valid, rd_req, frame_end, busy, shown;
  wire [7:0] cmd, wr_data;
  wire [23:0] addr;
  wire [15:0] frames;
  wire [3:0] s_out;
  wire s_oe;
  qspi_slave u_q (
      .clk(clk), .rd_start(8'd16), .rd_fall(1'b1), .sck(sck), .cs_n(cs_n), .d_in(m_out),
      .d_out(s_out), .d_oe(s_oe), .hdr_valid(hdr_valid), .cmd(cmd), .addr(addr),
      .wr_valid(wr_valid), .wr_data(wr_data), .rd_req(rd_req), .rd_data(8'd0),
      .frame_end(frame_end));

  vpx_t tim, px;
  video_timing u_tim (.clk(clk_pix), .rst(rst), .ce(1'b1), .px(tim));
  osd_plane dut (
      .clk(clk), .hdr_valid(hdr_valid), .cmd(cmd), .addr(addr), .wr_valid(wr_valid),
      .wr_data(wr_data), .frame_end(frame_end), .busy(busy), .shown(shown), .frames(frames),
      .clk_pix(clk_pix), .px_in(tim), .px_out(px));

  // ---- ESP ----
  localparam time T = 100ns;
  logic [7:0] wbuf [];
  task automatic nib_out(input logic [3:0] n);
    m_out = n;
    #(T / 2) sck = 1;
    #(T / 2) sck = 0;
  endtask
  task automatic q_write(input logic [7:0] c, input logic [23:0] a);
    cs_n = 0;
    #(T / 2);
    nib_out(c[7:4]);
    nib_out(c[3:0]);
    for (int i = 5; i >= 0; i--) nib_out(a[i*4+:4]);
    foreach (wbuf[i]) begin
      nib_out(wbuf[i][7:4]);
      nib_out(wbuf[i][3:0]);
    end
    #(T / 2) cs_n = 1;
    #(T * 2);
  endtask
  function automatic logic [23:0] yx(input int x, input int y);
    return {12'(y), 12'(x)};
  endfunction

  // ---- эталон ----
  logic [3:0] ref_idx [480][640];
  logic [23:0] ref_pal [16];
  bit ref_show = 0;
  initial begin
    foreach (ref_pal[i]) ref_pal[i] = {3{8'(i * 17)}};
    foreach (ref_idx[y, x]) ref_idx[y][x] = 'x;
  end
  function automatic logic [23:0] ref_rgb(input int x, input int y);
    int lx, ly;
    if (ref_show) return ref_pal[ref_idx[y][x]];
    lx = x - 120;
    ly = y - 182;
    if (lx >= 0 && lx < 400 && ly >= 0 && ly < 95)
      return dut.Logo[ly / 5][79 - lx / 5] ? 24'hFFFFFF : 24'h000000;
    return 24'h000000;
  endfunction

  task automatic osd_fill(input int x, input int y, input int w, input int h, input logic [7:0] c);
    wbuf = new[5];
    {wbuf[0], wbuf[1], wbuf[2], wbuf[3], wbuf[4]} = {16'(w), 16'(h), c};
    q_write(8'h41, yx(x, y));
    for (int j = y; j < y + h; j++)
      for (int i = x; i < x + w; i++)
        if (i < 640 && j < 480) ref_idx[j][i] = i[0] ? c[3:0] : c[7:4];
  endtask
  task automatic osd_rect(input int x, input int y, input int w, input int h, input int seed);
    int k = 4;
    wbuf = new[4 + w / 2 * h];
    {wbuf[0], wbuf[1], wbuf[2], wbuf[3]} = {16'(w), 16'(h)};
    for (int j = 0; j < h; j++)
      for (int i = 0; i < w; i += 2) begin
        wbuf[k] = 8'((i * 7 + j * 13 + seed) ^ (j << 3));
        if (x + i < 640 && y + j < 480) ref_idx[y+j][x+i] = wbuf[k][7:4];
        if (x + i + 1 < 640 && y + j < 480) ref_idx[y+j][x+i+1] = wbuf[k][3:0];
        k++;
      end
    q_write(8'h40, yx(x, y));
  endtask
  task automatic osd_pal(input int first, input logic [23:0] c []);
    wbuf = new[3 * c.size()];
    foreach (c[i]) {wbuf[3*i], wbuf[3*i+1], wbuf[3*i+2]} = c[i];
    q_write(8'h42, 24'(first));
    foreach (c[i]) ref_pal[first+i] = c[i];
  endtask

  // ---- снимок кадра с выхода ступени ----
  logic [23:0] shot [480][640];
  int shot_n = 0;
  always @(posedge clk_pix)
    if (px.de) shot[px.y][px.x] <= {px.r, px.g, px.b};
  always @(posedge clk_pix) if (px.de && px.x == 639 && px.y == 479) shot_n++;
  task automatic next_frame();
    int n0 = shot_n;
    wait (shot_n == n0 + 1);
    #100ns;
  endtask

  int errors = 0;
  task automatic check(input bit ok, input string what);
    if (ok) $display("ok   %s", what);
    else begin
      $display("FAIL %s", what);
      errors++;
    end
  endtask
  // кадр целиком против эталона: число несовпавших пикселей и первый из них
  task automatic compare(input string what);
    int bad = 0, fx = -1, fy = -1;
    next_frame();
    for (int y = 0; y < 480; y++)
      for (int x = 0; x < 640; x++)
        if (shot[y][x] !== ref_rgb(x, y)) begin
          if (bad == 0) begin
            fx = x;
            fy = y;
          end
          bad++;
        end
    if (bad == 0) check(1, what);
    else
      check(0, $sformatf("%s: %0d пикселей не совпали, первый (%0d, %0d) %06h, ждали %06h", what,
                         bad, fx, fy, shot[fy][fx], ref_rgb(fx, fy)));
  endtask
  task automatic save_ppm(input string path);
    int fd = $fopen(path, "wb");
    $fwrite(fd, "P6\n640 480\n255\n");
    for (int y = 0; y < 480; y++)
      for (int x = 0; x < 640; x++)
        $fwrite(fd, "%c%c%c", shot[y][x][23:16], shot[y][x][15:8], shot[y][x][7:0]);
    $fclose(fd);
  endtask

  initial begin
    int f0;
    wait (!rst);
    compare("заставка: логотип 400×95 в (120, 182) до OSD_CTRL");

    // всё поле фоном 0, потом показать плоскость
    osd_fill(0, 0, 640, 480, 8'h00);
    check(busy, "FILL: busy, пока идёт заливка");
    wait (!busy);
    wbuf = new[3];
    {wbuf[0], wbuf[1], wbuf[2]} = "FBK";
    q_write(8'h43, 24'h000001);
    check(!shown, "OSD_CTRL без ключа (3 байта) отброшен");
    wbuf = new[4];
    {wbuf[0], wbuf[1], wbuf[2], wbuf[3]} = "FBKY";
    q_write(8'h43, 24'h000001);
    check(shown, "OSD_CTRL с ключом FBKY");
    ref_show = 1;
    compare("FILL 640×480 цветом 0 и OSD_CTRL 1");

    osd_pal(1, '{24'h0A0A0A, 24'hE5E5E5, 24'h737373});
    osd_fill(16, 76, 608, 88, 8'h22);
    wait (!busy);
    osd_fill(100, 300, 40, 30, 8'h13);  // узор: чётные 1, нечётные 3
    wait (!busy);
    osd_rect(200, 60, 64, 20, 5);
    osd_rect(600, 470, 60, 16, 9);  // за правый и нижний край
    compare("PAL 1–3, FILL с узором, RECT 64×20 и RECT за краем экрана");

    // кадр во время заливки отброшен целиком
    osd_fill(0, 200, 640, 200, 8'h33);
    begin
      logic [3:0] keep [480][640];
      keep = ref_idx;
      osd_rect(20, 20, 8, 4, 1);
      ref_idx = keep;
      for (int j = 200; j < 400; j++)
        for (int i = 0; i < 640; i++) ref_idx[j][i] = 4'h3;
    end
    wait (!busy);
    compare("RECT во время заливки отброшен");

    f0 = frames;
    next_frame();
    next_frame();
    #2us;
    check(frames - f0 == 2, $sformatf("frames: +%0d за 2 кадра", frames - f0));
    save_ppm("build/tb_osd.ppm");

    if (errors) $display("ОШИБОК %0d", errors);
    else $display("ВСЁ OK");
    $finish;
  end

  initial begin
    #200ms;
    $display("TIMEOUT");
    $finish;
  end

endmodule
