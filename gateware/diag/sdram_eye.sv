`default_nettype none

// «Глаз» SDRAM на стенде: память NES (nes_sdram, 64,3 МГц) гоняет sdram_tester по всем 1M слов,
// фазу такта микросхемы ESP двигает шагами MMCM (19,8 пс) без пересборки. Регистры (CSR_R/CSR_W):
//   0 "SDRE"
//   1 управление: бит 0 run (гонять проходы)
//   2 состояние: [31:16] проходов, бит 1 тестер стоит (счётчики можно читать), бит 0 SDRAM занята
//   3 ошибок
//   4 первая ошибка: [31:24] прочитано, [23:16] ждали, [19:0]… слово в регистре 5
//   5 слово первой ошибки
//   6 фаза: запись — сдвинуть на N шагов (знаковое 16 бит); чтение — [15:0] положение в шагах,
//     бит 31 сдвиг идёт
// Счётчики тестера живут в домене clk и читаются с шины, только когда тестер стоит (бит 1).
module sdram_eye (
    input  wire        clk,        // 25 МГц
    output wire        led,
    output wire        uart_tx,
    input  wire        esp_sck,
    input  wire        esp_cs_n,
    inout  wire  [3:0] esp_d,
    output wire        esp_irq,
    output wire        sdram_clk,
    output wire [10:0] sdram_a,
    output wire  [1:0] sdram_ba,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    inout  wire [31:0] sdram_dq
);
  assign uart_tx = 1'b1;

  // ---- шина ESP ----
  wire clk_bus, rst_bus, csr_we;
  wire [7:0] csr_waddr, csr_raddr;
  wire [31:0] csr_wdata;
  logic [31:0] csr_rdata;
  profile_bus #(.ProfileId(16'h00E1)) u_bus (
      .clk_25m(clk), .esp_sck(esp_sck), .esp_cs_n(esp_cs_n), .esp_d(esp_d), .esp_irq(esp_irq),
      .clk_bus(clk_bus), .rst_bus(rst_bus), .csr_we(csr_we), .csr_waddr(csr_waddr),
      .csr_wdata(csr_wdata), .csr_raddr(csr_raddr), .csr_rdata(csr_rdata), .st_valid(),
      .st_chan(), .st_data());

  // ---- такты NES и сдвиг фазы (интерфейс PS в домене шины) ----
  wire nclk, fclk, sd_clk_int, locked, psdone;
  logic psen = 1'b0, psincdec = 1'b0, ps_busy = 1'b0;
  logic signed [15:0] ps_left = '0, ps_pos = '0;
  nes_clocks u_nesclk (
      .clk_25m(clk), .psclk(clk_bus), .psen(psen), .psincdec(psincdec), .psdone(psdone),
      .clk(nclk), .fclk(fclk), .sdram_clk(sd_clk_int), .locked(locked));

  always_ff @(posedge clk_bus) begin
    psen <= 1'b0;
    if (rst_bus) begin
      ps_left <= '0;
      ps_busy <= 1'b0;
    end else begin
      if (csr_we && csr_waddr == 8'd6) ps_left <= ps_left + signed'(csr_wdata[15:0]);
      if (psdone) ps_busy <= 1'b0;
      if (!ps_busy && ps_left != 0 && locked && !(csr_we && csr_waddr == 8'd6)) begin
        psen     <= 1'b1;
        psincdec <= ps_left > 0;
        ps_busy  <= 1'b1;
        ps_left  <= ps_left > 0 ? ps_left - 1'b1 : ps_left + 1'b1;
        ps_pos   <= ps_left > 0 ? ps_pos + 1'b1 : ps_pos - 1'b1;
      end
    end
  end

  // ---- управление в домен ядра ----
  logic run_bus = 1'b0;
  always_ff @(posedge clk_bus)
    if (rst_bus) run_bus <= 1'b0;
    else if (csr_we && csr_waddr == 8'd1) run_bus <= csr_wdata[0];

  wire rst_n_clk, run;
  reset_sync u_rst (.clk(nclk), .rst_in(!locked), .rst_out(rst_n_clk));
  sync_bit u_run (.clk(nclk), .d(run_bus), .q(run));

  // ---- память и тестер ----
  wire clkref, mem_busy, oe_a, oe_b, we_b;
  wire [21:0] addr;
  wire [7:0] din, dout_a, dout_b, err_got, err_want;
  wire [15:0] passes;
  wire [31:0] errors;
  wire [21:0] err_addr;
  wire idle_clk;
  nes_sdram #(.Remap(1'b0)) u_mem (
      .clk(nclk), .fclk(fclk), .sdram_clk(sd_clk_int), .rst(rst_n_clk), .clkref_sync(1'b0),
      .clkref(clkref), .busy(mem_busy),
      .addr_a(addr), .oe_a(oe_a), .we_a(1'b0), .din_a(8'd0), .dout_a(dout_a),
      .addr_b(addr), .oe_b(oe_b), .we_b(we_b), .din_b(din), .dout_b(dout_b),
      .sd_clk(sdram_clk), .sd_a(sdram_a), .sd_ba(sdram_ba), .sd_ras_n(sdram_ras_n),
      .sd_cas_n(sdram_cas_n), .sd_we_n(sdram_we_n), .sd_dq(sdram_dq));

  sdram_tester #(.AddrBits(20)) u_t (
      .clk(nclk), .rst(rst_n_clk), .run(run), .clkref(clkref), .mem_busy(mem_busy),
      .addr(addr), .oe_a(oe_a), .oe_b(oe_b), .we_b(we_b), .din(din), .dout_a(dout_a),
      .dout_b(dout_b), .passes(passes), .errors(errors), .err_addr(err_addr),
      .err_got(err_got), .err_want(err_want), .idle(idle_clk));

  wire idle, busy_bus;
  sync_bit u_idle (.clk(clk_bus), .d(idle_clk), .q(idle));
  sync_bit u_busy (.clk(clk_bus), .d(mem_busy), .q(busy_bus));

  always_comb
    case (csr_raddr)
      8'd0: csr_rdata = "SDRE";
      8'd1: csr_rdata = {31'd0, run_bus};
      8'd2: csr_rdata = {passes, 14'd0, idle, busy_bus};
      8'd3: csr_rdata = errors;
      8'd4: csr_rdata = {err_got, err_want, 16'd0};
      8'd5: csr_rdata = {10'd0, err_addr};
      8'd6: csr_rdata = {ps_busy || ps_left != 0, 15'd0, ps_pos};
      default: csr_rdata = '0;
    endcase

  // светодиод: мигает, пока идут проходы; горит, если были ошибки
  logic [23:0] blink = '0;
  always_ff @(posedge nclk) blink <= blink + 1'b1;
  assign led = (errors != 0) ? 1'b1 : (run && blink[23]);

endmodule
