`default_nettype none
`timescale 1ns / 1ps

// fifo_async на двух несвязанных тактах (быстрая запись → медленное чтение и наоборот), случайные
// valid и ready: все слова доходят по порядку, без потерь и повторов; полная FIFO держит запись.
module tb_cdc;
  int errors = 0;

  task automatic check(input bit ok, input string what);
    if (ok) $display("ok   %s", what);
    else begin
      $display("FAIL %s", what);
      errors++;
    end
  endtask

  // один прогон: периоды тактов в пс, число слов
  task automatic run(input int wper_ps, input int rper_ps, input int n, input string name);
    // процессы ниже работают через интерфейсные переменные модуля
    wper = wper_ps;
    rper = rper_ps;
    total = n;
    sent = 0;
    got = 0;
    bad = 0;
    full_seen = 0;
    rst = 1;
    #50ns;
    rst = 0;
    wait (got == n || $time > 50ms);
    check(got == n && bad == 0,
          $sformatf("%s: принято %0d из %0d, ошибок %0d", name, got, n, bad));
    check(full_seen, $sformatf("%s: FIFO заполнялась и держала запись", name));
  endtask

  int wper = 10000, rper = 46600, total = 0, sent = 0, got = 0, bad = 0;
  bit full_seen = 0;
  logic rst = 1, wclk = 0, rclk = 0;
  always #(wper * 1ps / 2) wclk = ~wclk;
  always #(rper * 1ps / 2) rclk = ~rclk;

  logic in_valid = 0, out_ready = 0;
  logic [15:0] in_data = '0;
  wire in_ready, out_valid;
  wire [15:0] out_data;
  wire [6:0] wlevel;

  fifo_async #(.Width(16), .Depth(64)) dut (
      .wclk(wclk), .wrst(rst), .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
      .wlevel(wlevel),
      .rclk(rclk), .rrst(rst), .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data));

  always @(posedge wclk) begin
    if (rst) begin
      in_valid <= 0;
    end else begin
      if (in_valid && in_ready) sent <= sent + 1;
      if (!in_ready) full_seen <= 1;
      // новое слово, когда текущее принято или его нет
      if (!in_valid || in_ready) begin
        in_valid <= (sent + (in_valid && in_ready) < total) && ($urandom % 4 != 0);
        in_data  <= 16'(sent + (in_valid && in_ready));
      end
    end
  end

  always @(posedge rclk) begin
    if (rst) begin
      out_ready <= 0;
    end else begin
      if (out_valid && out_ready) begin
        if (out_data !== 16'(got)) bad <= bad + 1;
        got <= got + 1;
      end
      // медленный читатель: первые 200 слов редко забирает, чтобы FIFO заполнилась
      out_ready <= (got < 200) ? ($urandom % 16 == 0) : ($urandom % 3 != 0);
    end
  end

  initial begin
    run(10000, 46600, 3000, "запись 100 МГц → чтение 21,46 МГц");
    run(46600, 15530, 3000, "запись 21,46 МГц → чтение 64,4 МГц");
    run(39702, 10000, 3000, "запись 25,19 МГц → чтение 100 МГц");
    if (errors) $fatal(1, "ОШИБОК %0d", errors);
    else $display("ВСЁ OK");
    $finish;
  end

endmodule
