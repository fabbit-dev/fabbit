`default_nettype none
`timescale 1ns / 1ps

// Видеотракт целиком: video_timing → video_pattern → hdmi_tx → ножки. Тест снимает последовательный
// поток с ножек, сам находит границу слова по управляющим словам, декодирует TMDS и сверяет
// каждый видимый пиксель с тем, что источник отдал на вход hdmi_tx.
module tb_video;
  import video_pkg::*;

  logic clk_pix = 0, clk_5x = 0, rst = 1;
  always #20 clk_pix = ~clk_pix;  // 25 МГц
  always #4 clk_5x = ~clk_5x;     // 125 МГц, фронты совпадают с clk_pix

  logic [1:0] sel = 2'd0;
  vpx_t tim, pat;
  wire [3:0] pad_p, pad_n;

  video_timing u_tim (.clk(clk_pix), .rst(rst), .ce(1'b1), .px(tim));
  video_pattern u_pat (.clk(clk_pix), .ce(1'b1), .sel(sel), .px_in(tim), .px_out(pat));
  hdmi_tx u_tx (.clk_pix(clk_pix), .clk_5x(clk_5x), .px(pat), .pad_p(pad_p), .pad_n(pad_n));

  int errors = 0;
  task automatic check(input bit ok, input string what);
    if (ok) $display("ok   %s", what);
    else begin
      $display("FAIL %s", what);
      errors++;
    end
  endtask

  // эталон: видимые пиксели в порядке выхода из источника, начиная с кадра 1 (кадр 0 приёмник
  // пропускает: ищет границу слова и первый кадровый синхроимпульс)
  logic [23:0] want [$];
  int frame_src = -1;
  always @(posedge clk_pix)
    if (!rst) begin
      if (pat.sof) frame_src <= frame_src + 1;
      if (pat.de && (frame_src >= 1 || (pat.sof && frame_src == 0)))
        want.push_back({pat.r, pat.g, pat.b});
    end

  // строчный синхро: длина последнего импульса
  int hs_len = 0, hs_run = 0;
  always @(posedge clk_pix)
    if (!rst) begin
      hs_run <= tim.hs ? 0 : hs_run + 1;
      if (!tim.hs) hs_len <= hs_run + 1;
    end

  // ---- приём: биты с ножек (середина бита: 2 нс после фронта clk_5x) ----
  logic [9:0] sh [4];
  logic [3:0] err_pn = '0;
  int bitn = 0;
  task automatic take_bit();
    #2;
    for (int l = 0; l < 4; l++) begin
      sh[l] = {pad_p[l], sh[l][9:1]};
      if (pad_n[l] !== ~pad_p[l]) err_pn[l] = 1;
    end
    bitn++;
  endtask
  always @(posedge clk_5x) take_bit();
  always @(negedge clk_5x) take_bit();

  function automatic logic [7:0] tmds_dec(input logic [9:0] w);
    logic [7:0] d, o;
    d = w[9] ? ~w[7:0] : w[7:0];
    o[0] = d[0];
    for (int i = 1; i < 8; i++) o[i] = w[8] ? d[i] ^ d[i-1] : d[i] ~^ d[i-1];
    return o;
  endfunction

  function automatic bit is_ctrl(input logic [9:0] w);
    return w inside {10'b1101010100, 10'b0010101011, 10'b0101010100, 10'b1010101011};
  endfunction

  // выравнивание: позиция бита, где на линиях 1 и 2 подряд 64 управляющих слова;
  // сверка с эталоном с первого кадра после кадрового синхро (vs = 0 в слове линии 0)
  int phase = -1, ctrl_run [10];
  bit vs_seen = 0;
  int got = 0, mism = 0, clk_bad = 0, words = 0;
  int disp [3] = '{0, 0, 0}, disp_max = 0;
  initial foreach (ctrl_run[i]) ctrl_run[i] = 0;

  always @(posedge clk_5x or negedge clk_5x) begin
    #3;
    if (phase < 0) begin
      int p;
      p = bitn % 10;
      if (is_ctrl(sh[1]) && is_ctrl(sh[2])) ctrl_run[p]++;
      else ctrl_run[p] = 0;
      if (ctrl_run[p] == 64) phase = p;
    end else if (bitn % 10 == phase) begin
      words++;
      if (sh[3] !== 10'b0000011111) clk_bad++;
      if (sh[0] inside {10'b1101010100, 10'b0010101011}) vs_seen = 1;  // c[1] = vs = 0
      if (is_ctrl(sh[2])) disp = '{0, 0, 0};  // кодер обнуляет баланс в гашении
      else if (vs_seen) begin
        logic [23:0] px, w;
        px = {tmds_dec(sh[2]), tmds_dec(sh[1]), tmds_dec(sh[0])};
        for (int l = 0; l < 3; l++) begin
          disp[l] += $countones(sh[l]) - 5;
          if (disp[l] > disp_max) disp_max = disp[l];
          if (-disp[l] > disp_max) disp_max = -disp[l];
        end
        if (want.size()) begin
          w = want.pop_front();
          if (w !== px && mism++ < 5) $display("  пиксель %0d: %06h вместо %06h", got, px, w);
          got++;
        end
      end
    end
  end

  // ---- сценарий ----
  initial begin
    repeat (4) @(posedge clk_pix);
    rst = 0;
    // строка и синхро
    @(posedge clk_pix iff tim.x == 0 && tim.y == 0);
    begin
      automatic int n = 0;
      @(posedge clk_pix);
      while (!(tim.x == 0)) begin
        n++;
        @(posedge clk_pix);
      end
      check(n + 1 == 800, $sformatf("длина строки %0d тактов (800)", n + 1));
    end
    begin
      automatic int n = 0;
      @(posedge clk_pix iff tim.sof);
      @(posedge clk_pix);
      while (!tim.sof) begin
        n++;
        @(posedge clk_pix);
      end
      check(n + 1 == 800 * 525, $sformatf("длина кадра %0d тактов (800×525)", n + 1));
      check(hs_len == 96, $sformatf("строчный синхро %0d тактов (96), отрицательный", hs_len));
    end
    // 2 кадра полос (с бегущей диагональю), затем кадр сетки и кадр градиентов
    @(posedge clk_pix iff tim.sof);
    @(posedge clk_pix iff tim.sof);
    sel = 2'd1;
    @(posedge clk_pix iff tim.sof);
    sel = 2'd2;
    @(posedge clk_pix iff tim.sof);
    repeat (200) @(posedge clk_pix);
    check(phase >= 0, $sformatf("граница слова найдена (бит %0d)", phase));
    check(got >= 3 * 640 * 480, $sformatf("принято пикселей %0d (≥ 3 кадров)", got));
    check(mism == 0, $sformatf("несовпадений пикселей %0d", mism));
    check(clk_bad == 0,
          $sformatf("слово линии такта 0000011111: ошибок %0d из %0d", clk_bad, words));
    check(err_pn == 0, $sformatf("N = инверсия P на всех линиях (сбой: %b)", err_pn));
    check(disp_max <= 10, $sformatf("баланс линий: |сумма(1−0)/2| ≤ %0d", disp_max));
    if (errors) $fatal(1, "ОШИБОК %0d", errors);
    else $display("ВСЁ OK");
    $finish;
  end

  initial begin
    #200ms;
    $fatal(1, "TIMEOUT");
  end

endmodule
