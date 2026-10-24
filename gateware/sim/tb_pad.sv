`default_nettype none
`timescale 1ns / 1ps

// Кнопки до ядра: cdc_word переносит слово пада из домена шины (100 МГц) в домен ядра (21,43 МГц)
// целиком, без промежуточных слов; nes_pad даёт раскладку NES, турбо 10 Гц и снимает
// противоположные направления.
module tb_pad;
  int errors = 0;
  task automatic check(input bit ok, input string what);
    if (ok) $display("ok   %s", what);
    else begin
      $display("FAIL %s", what);
      errors++;
    end
  endtask

  logic sclk = 0, dclk = 0;
  always #5ns sclk = ~sclk;
  always #23.33ns dclk = ~dclk;

  // ---- cdc_word: случайные слова через 1,6–5 мкс, как кадры PAD ----
  logic stb = 0;
  logic [31:0] d = '0;
  wire [31:0] q;
  wire q_stb;
  cdc_word #(.Width(32)) u_x (.sclk(sclk), .stb(stb), .d(d), .dclk(dclk), .q(q), .q_stb(q_stb));

  logic [31:0] sent [$];
  int got = 0, bad = 0, torn = 0;
  always @(posedge dclk) begin
    if (q_stb) begin
      if (got < sent.size() && q == sent[got]) got++;
      else bad++;
    end
  end
  // между стробами выход не меняется: проверка на каждом такте
  logic [31:0] q_prev = '0;
  always @(posedge dclk) begin
    if (q != q_prev && !q_stb) torn++;
    q_prev <= q;
  end

  // ---- nes_pad ----
  logic frame = 0;
  logic [15:0] pad = '0;
  wire [7:0] joy;
  nes_pad u_p (.clk(dclk), .frame(frame), .pad(pad), .joy(joy));
  task automatic frames(input int n);
    repeat (n) begin
      @(posedge dclk) frame <= 1;
      @(posedge dclk) frame <= 0;
      repeat (10) @(posedge dclk);
    end
  endtask

  initial begin
    #200ns;
    for (int i = 0; i < 500; i++) begin
      logic [31:0] w;
      w = $urandom;
      @(posedge sclk) begin
        d <= w;
        stb <= 1;
      end
      sent.push_back(w);
      @(posedge sclk) stb <= 0;
      #($urandom_range(1600, 5000) * 1ns);
    end
    #1us;
    check(got == 500 && bad == 0 && torn == 0,
          $sformatf("cdc_word: 500 слов, принято %0d, чужих %0d, смен без строба %0d",
                    got, bad, torn));

    // раскладка: Up Down Left Right A B X Y = 0..7, Select 14, Start 15
    pad = 16'h0010; frames(1); @(posedge dclk); @(posedge dclk);
    check(joy == 8'h01, $sformatf("A → NES A: %02h", joy));
    pad = 16'h0020; @(posedge dclk); @(posedge dclk);
    check(joy == 8'h02, $sformatf("B → NES B: %02h", joy));
    pad = 16'h4000; @(posedge dclk); @(posedge dclk);
    check(joy == 8'h04, $sformatf("Select: %02h", joy));
    pad = 16'h8000; @(posedge dclk); @(posedge dclk);
    check(joy == 8'h08, $sformatf("Start: %02h", joy));
    pad = 16'h0009; @(posedge dclk); @(posedge dclk);
    check(joy == 8'h90, $sformatf("Вверх+Вправо: %02h", joy));
    pad = 16'h0003; @(posedge dclk); @(posedge dclk);
    check(joy == 8'h00, $sformatf("Вверх+Вниз снимаются: %02h", joy));
    pad = 16'h000C; @(posedge dclk); @(posedge dclk);
    check(joy == 8'h00, $sformatf("Влево+Вправо снимаются: %02h", joy));

    // турбо: X → A, Y → B, по 3 кадра нажато и 3 отпущено
    begin
      string seq = "";
      int on = 0;
      pad = 16'h00C0;
      for (int f = 0; f < 12; f++) begin
        frames(1);
        @(posedge dclk); @(posedge dclk);
        seq = {seq, joy == 8'h03 ? "1" : joy == 8'h00 ? "0" : "?"};
        on += joy == 8'h03;
      end
      check(on == 6 && seq != "" && (seq.substr(0, 5) == "111000" || seq.substr(0, 5) == "000111" ||
            seq.substr(0, 5) == "110001" || seq.substr(0, 5) == "100011" ||
            seq.substr(0, 5) == "001110" || seq.substr(0, 5) == "011100"),
            $sformatf("турбо X+Y: кадры %s (3 через 3)", seq));
    end
    pad = 16'h00D0; @(posedge dclk); @(posedge dclk);
    check(joy[0], "A держится при турбо A");

    if (errors) $display("ОШИБОК %0d", errors);
    else $display("ВСЁ OK");
    $finish;
  end
  initial begin
    #20ms;
    $display("TIMEOUT");
    $finish;
  end
endmodule
