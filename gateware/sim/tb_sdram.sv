`default_nettype none
`timescale 1ns / 1ps

// nes_sdram (контроллер ядра sdram_nes, 32 бит, CL2) + sdram_tester против модели SDRAM.
// Такт микросхемы сдвинут относительно fclk на +phase_ps=N (плюс-аргумент), как фаза MMCM на стенде.
// +expect=ok: 2 прохода без ошибок; +expect=fail: вне окна тестер обязан найти ошибки (проверка тестера).
// Окно при нулевых задержках: sdram_nes берёт данные на CAS + 3 такта при CL2, поэтому фронт микросхемы
// должен опережать fclk на 0…tOH (2,5 нс): сдвиг 13–15,5 нс. На плате окно сдвигают задержки выводов
// и дорожек, его ищет diag/sdram_eye перебором фазы MMCM.
module tb_sdram;
  localparam time Tf = 15556ps;  // fclk 64,286 МГц
  logic fclk = 0, clk = 0, sdram_clk = 0;
  time phase;
  int ps;
  initial begin
    if (!$value$plusargs("phase_ps=%d", ps)) ps = 14500;  // окно модели: 13–15,5 нс (см. ниже)
    phase = ps * 1ps;
  end
  always #(Tf / 2) fclk = ~fclk;
  initial begin
    #(phase);
    forever #(Tf / 2) sdram_clk = ~sdram_clk;
  end
  int div = 0;
  always @(posedge fclk) begin  // clk = fclk / 3, фронты совпадают
    div <= (div == 2) ? 0 : div + 1;
    if (div == 0) clk <= 1;
    if (div == 1) clk <= 0;
  end

  logic rst = 1, run = 0;
  wire clkref, busy, oe_a, oe_b, we_b;
  wire [21:0] addr;
  wire [7:0] din, dout_a, dout_b;
  wire [15:0] passes;
  wire [31:0] errors;
  wire [21:0] err_addr;
  wire [7:0] err_got, err_want;
  wire sd_clk, ras_n, cas_n, we_n;
  wire [10:0] sd_a;
  wire [1:0] sd_ba;
  wire [31:0] sd_dq;

  nes_sdram #(.Remap(1'b0)) u_mem (
      .clk(clk), .fclk(fclk), .sdram_clk(sdram_clk), .rst(rst), .clkref_sync(1'b0),
      .clkref(clkref), .busy(busy),
      .addr_a(addr), .oe_a(oe_a), .we_a(1'b0), .din_a(8'd0), .dout_a(dout_a),
      .addr_b(addr), .oe_b(oe_b), .we_b(we_b), .din_b(din), .dout_b(dout_b),
      .sd_clk(sd_clk), .sd_a(sd_a), .sd_ba(sd_ba), .sd_ras_n(ras_n), .sd_cas_n(cas_n),
      .sd_we_n(we_n), .sd_dq(sd_dq));

  sdram_tester #(.AddrBits(11)) u_t (
      .clk(clk), .rst(rst), .run(run), .clkref(clkref), .mem_busy(busy), .addr(addr),
      .oe_a(oe_a), .oe_b(oe_b), .we_b(we_b), .din(din), .dout_a(dout_a), .dout_b(dout_b),
      .passes(passes), .errors(errors), .err_addr(err_addr), .err_got(err_got),
      .err_want(err_want), .idle());

  // DQM у микросхемы на i9+ не разведён: все байты всегда активны (модель тоже)
  sdram_model u_sd (
      .clk(sd_clk), .cke(1'b1), .cs_n(1'b0), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
      .ba(sd_ba), .a(sd_a), .dqm(4'b0000), .dq(sd_dq));

  int fails = 0;
  task automatic check(input bit ok, input string what);
    if (ok) $display("ok   %s", what);
    else begin
      $display("FAIL %s", what);
      fails++;
    end
  endtask

  // прогон: сброс, 2 прохода по 2 КБ
  task automatic trial(output int errs, output int model_errs);
    rst = 1;
    run = 0;
    repeat (8) @(posedge clk);
    rst = 0;
    run = 1;
    wait (passes == 2);
    run = 0;
    repeat (8) @(posedge clk);
    errs = errors;
    model_errs = u_sd.errors;
  endtask

  initial begin
    int e, m;
    string mode;
    if (!$value$plusargs("expect=%s", mode)) mode = "ok";
    trial(e, m);
    if (mode == "ok") begin
      check(e == 0 && m == 0,
            $sformatf("сдвиг %0d пс: 2 прохода, ошибок %0d, нарушений модели %0d", ps, e, m));
      if (e)
        $display("  первая: слово %06h прочитано %02h ждали %02h", err_addr, err_got, err_want);
    end else begin
      check(e != 0, $sformatf("сдвиг %0d пс (вне окна): тестер видит ошибки (%0d)", ps, e));
    end
    if (fails) $fatal(1, "ОШИБОК %0d", fails);
    else $display("ВСЁ OK");
    $finish;
  end

endmodule
