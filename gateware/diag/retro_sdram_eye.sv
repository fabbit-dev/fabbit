`default_nettype none

// «Глаз» SDRAM на частотах ретро-профиля: контроллер retro_sdram гоняет 32-битный тестер,
// фазу такта микросхемы ESP двигает тонким сдвигом MMCM без пересборки.
// Mode 0 MD: 53,693 МГц, CL3, MMCM 25×47,25/22 как retro_clocks (шаг 15,12 пс, 1232 на период).
// Mode 1 SNES: 85,909 МГц, CL2, каскад 25×47,25/55 → ×40/10 как retro_snes_clocks
// (шаг 20,78 пс, 560 на период). Захват READ через CAS тактов, как у snes_memory.
// Фаза 0 = фаза профиля (MD 38,86°, SNES 63°): окно сравнивается с ней.
// Регистры совместимы с diag/sdram_eye и командами eye/soak ESP; добавлены 7..9:
//   0 "SDRE"; 1 бит 0 run; 2 [31:16] проходов, бит 1 тестер стоит, бит 0 память не готова
//   3 ошибок; 4 [31:24] первые прочитанные биты 7:0, [23:16] ждали; 5 слово первой ошибки
//   6 фаза: запись сдвиг на N шагов, чтение [15:0] положение, бит 31 сдвиг идёт
//   7 шагов на период; 8 log2 слов в проходе (запись, 4..21, по умолчанию 16); 9 шаг, фс
module retro_sdram_eye #(
    parameter bit Mode = 1'b0
) (
    input  wire        clk,
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
  localparam int Period = Mode ? 560 : 1232;
  localparam int StepFs = Mode ? 20779 : 15117;

  wire clk_bus, rst_bus, csr_we;
  wire [7:0] csr_waddr, csr_raddr;
  wire [31:0] csr_wdata;
  logic [31:0] csr_rdata;
  profile_bus #(.ProfileId(16'h00E2)) u_bus (
      .clk_25m(clk), .esp_sck, .esp_cs_n, .esp_d, .esp_irq,
      .clk_bus, .rst_bus, .csr_we, .csr_waddr, .csr_wdata, .csr_raddr, .csr_rdata,
      .st_valid(), .st_chan(), .st_data(), .pad(), .pad_stb());

  // ---- такты: контроллер и копия для SDRAM с тонким сдвигом ----
  wire mclk, sd_clk_int, locked, psdone;
  logic psen = 1'b0, psincdec = 1'b0, ps_busy = 1'b0;
  wire ctl_raw, sd_raw;
  if (Mode) begin : g_snes
    wire fb1, fb1_buf, src_raw, src, locked1, fb2, fb2_buf, locked2;
    MMCME2_ADV #(.CLKIN1_PERIOD(40.0), .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(47.25),
        .CLKOUT0_DIVIDE_F(55.0)) u_src (
        .CLKIN1(clk), .CLKIN2(1'b0), .CLKINSEL(1'b1), .CLKFBIN(fb1_buf), .CLKFBOUT(fb1),
        .CLKOUT0(src_raw), .LOCKED(locked1), .RST(1'b0), .PWRDWN(1'b0),
        .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0), .PSDONE(),
        .DADDR(7'd0), .DCLK(1'b0), .DEN(1'b0), .DI(16'd0), .DWE(1'b0), .DO(), .DRDY(),
        .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .CLKINSTOPPED(), .CLKFBSTOPPED());
    BUFG u_fb1 (.I(fb1), .O(fb1_buf));
    BUFG u_src_buf (.I(src_raw), .O(src));
    MMCME2_ADV #(.CLKIN1_PERIOD(46.56084656), .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(40.0),
        .CLKOUT0_DIVIDE_F(10.0), .CLKOUT2_DIVIDE(10), .CLKOUT2_PHASE(63.0),
        .CLKOUT2_USE_FINE_PS("TRUE")) u_mem (
        .CLKIN1(src), .CLKIN2(1'b0), .CLKINSEL(1'b1), .CLKFBIN(fb2_buf), .CLKFBOUT(fb2),
        .CLKOUT0(ctl_raw), .CLKOUT2(sd_raw), .LOCKED(locked2), .RST(!locked1), .PWRDWN(1'b0),
        .PSCLK(clk_bus), .PSEN(psen), .PSINCDEC(psincdec), .PSDONE(psdone),
        .DADDR(7'd0), .DCLK(1'b0), .DEN(1'b0), .DI(16'd0), .DWE(1'b0), .DO(), .DRDY(),
        .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .CLKINSTOPPED(), .CLKFBSTOPPED());
    BUFG u_fb2 (.I(fb2), .O(fb2_buf));
    assign locked = locked1 && locked2;
  end else begin : g_md
    wire fb, fb_buf;
    MMCME2_ADV #(.CLKIN1_PERIOD(40.0), .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(47.25),
        .CLKOUT0_DIVIDE_F(22.0), .CLKOUT2_DIVIDE(22), .CLKOUT2_PHASE(38.863636),
        .CLKOUT2_USE_FINE_PS("TRUE")) u_mem (
        .CLKIN1(clk), .CLKIN2(1'b0), .CLKINSEL(1'b1), .CLKFBIN(fb_buf), .CLKFBOUT(fb),
        .CLKOUT0(ctl_raw), .CLKOUT2(sd_raw), .LOCKED(locked), .RST(1'b0), .PWRDWN(1'b0),
        .PSCLK(clk_bus), .PSEN(psen), .PSINCDEC(psincdec), .PSDONE(psdone),
        .DADDR(7'd0), .DCLK(1'b0), .DEN(1'b0), .DI(16'd0), .DWE(1'b0), .DO(), .DRDY(),
        .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .CLKINSTOPPED(), .CLKFBSTOPPED());
    BUFG u_fb (.I(fb), .O(fb_buf));
  end
  BUFG u_ctl (.I(ctl_raw), .O(mclk));
  BUFG u_sd (.I(sd_raw), .O(sd_clk_int));
  ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) u_fwd (
      .C(sd_clk_int), .CE(1'b1), .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0), .Q(sdram_clk));

  // ---- сдвиг фазы (домен шины) ----
  logic signed [15:0] ps_left = '0, ps_pos = '0;
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

  // ---- управление в домен памяти; длина прохода меняется только при остановленном тестере ----
  logic run_bus = 1'b0;
  logic [4:0] bits_bus = 5'd16;
  always_ff @(posedge clk_bus)
    if (rst_bus) begin
      run_bus <= 1'b0;
      bits_bus <= 5'd16;
    end else if (csr_we) begin
      if (csr_waddr == 8'd1) run_bus <= csr_wdata[0];
      if (csr_waddr == 8'd8 && csr_wdata[4:0] >= 4 && csr_wdata[4:0] <= 21)
        bits_bus <= csr_wdata[4:0];
    end
  wire rst_mem, run;
  reset_sync u_rst (.clk(mclk), .rst_in(!locked), .rst_out(rst_mem));
  sync_bit u_run (.clk(mclk), .d(run_bus), .q(run));
  logic [4:0] bits = 5'd16;

  // ---- контроллер и тестер ----
  wire init, req_ready, rsp_valid;
  logic req_valid = 1'b0, req_write = 1'b0;
  logic [20:0] req_addr = '0;
  logic [31:0] req_wdata = '0;
  wire [31:0] rsp_rdata, dq_in, dq_out;
  wire dq_oe;
  retro_sdram #(
      .InitCycles(Mode ? 18000 : 10740), .RefreshCycles(Mode ? 480 : 375),
      .Trcd(2), .Trp(2), .Trfc(Mode ? 6 : 4), .Tras(Mode ? 4 : 3), .Twr(2), .Tmrd(2),
      .Cas(Mode ? 2 : 3)
  ) u_mem (
      .clk(mclk), .rst(rst_mem), .initialized(init), .req_valid, .req_ready, .req_write,
      .req_addr, .req_wdata, .rsp_valid, .rsp_ready(1'b1), .rsp_rdata,
      .sd_a(sdram_a), .sd_ba(sdram_ba), .sd_ras_n(sdram_ras_n), .sd_cas_n(sdram_cas_n),
      .sd_we_n(sdram_we_n), .sd_dq_in(dq_in), .sd_dq_out(dq_out), .sd_dq_oe(dq_oe));
  retro_sdram_io u_io (.dq_out, .dq_oe, .dq_in, .sd_dq(sdram_dq));

  function automatic logic [31:0] pattern(input logic [20:0] a, input logic [15:0] p);
    logic [31:0] h;
    h = {11'd0, a} * 32'h9E37_79B1 ^ {p, p};
    return h ^ {h[15:0], h[31:16]} ^ {a[7:0], a[20:8], 11'd0};
  endfunction

  typedef enum logic [1:0] {Idle, Write, Read} phase_t;
  phase_t phase = Idle;
  logic [15:0] passes = '0;
  logic [31:0] errors = '0, err_word = '0;
  logic [7:0] err_got = '0, err_want = '0;
  logic [20:0] last_addr = '0;
  logic waiting = 1'b0;
  wire [20:0] top = 21'((32'd1 << bits) - 1);
  always_ff @(posedge mclk)
    if (rst_mem) begin
      phase <= Idle;
      req_valid <= 1'b0;
      waiting <= 1'b0;
      passes <= '0;
      errors <= '0;
    end else begin
      if (req_valid && req_ready) begin
        req_valid <= 1'b0;
        waiting <= 1'b1;
      end
      case (phase)
        Idle: if (run && init) begin
          bits <= bits_bus;
          phase <= Write;
          req_addr <= '0;
          req_write <= 1'b1;
          req_wdata <= pattern(21'd0, passes);
          req_valid <= 1'b1;
        end
        Write: if (waiting && rsp_valid) begin
          waiting <= 1'b0;
          if (req_addr == top) begin
            phase <= Read;
            req_addr <= '0;
            req_write <= 1'b0;
          end else begin
            req_addr <= req_addr + 1'b1;
            req_wdata <= pattern(req_addr + 1'b1, passes);
          end
          req_valid <= 1'b1;
        end
        Read: if (waiting && rsp_valid) begin
          waiting <= 1'b0;
          if (rsp_rdata != pattern(req_addr, passes)) begin
            if (errors == 0) begin
              err_word <= {11'd0, req_addr};
              err_got <= rsp_rdata[7:0];
              err_want <= 8'(pattern(req_addr, passes));
            end
            if (errors != '1) errors <= errors + 1'b1;
          end
          if (req_addr == top) begin
            passes <= passes + 1'b1;
            phase <= Idle;
          end else begin
            req_addr <= req_addr + 1'b1;
            req_valid <= 1'b1;
          end
        end
        default: phase <= Idle;
      endcase
    end

  wire idle, busy;
  sync_bit u_idle (.clk(clk_bus), .d(phase == Idle && !run), .q(idle));
  sync_bit u_busy (.clk(clk_bus), .d(!init), .q(busy));
  always_comb
    case (csr_raddr)
      8'd0: csr_rdata = "SDRE";
      8'd1: csr_rdata = {31'd0, run_bus};
      8'd2: csr_rdata = {passes, 14'd0, idle, busy};
      8'd3: csr_rdata = errors;
      8'd4: csr_rdata = {err_got, err_want, 16'd0};
      8'd5: csr_rdata = err_word;
      8'd6: csr_rdata = {ps_busy || ps_left != 0, 15'd0, ps_pos};
      8'd7: csr_rdata = Period;
      8'd8: csr_rdata = {27'd0, bits_bus};
      8'd9: csr_rdata = StepFs;
      default: csr_rdata = '0;
    endcase

  logic [23:0] blink = '0;
  always_ff @(posedge mclk) blink <= blink + 1'b1;
  assign led = (errors != 0) ? 1'b1 : (run && blink[23]);
endmodule
`default_nettype wire
`default_nettype none
// Отдельные верхние модули: у каждого свой битстрим build/vivado/<верх>.bit.
module retro_sdram_eye_md (
    input wire clk, output wire led, uart_tx, input wire esp_sck, esp_cs_n,
    inout wire [3:0] esp_d, output wire esp_irq, sdram_clk, output wire [10:0] sdram_a,
    output wire [1:0] sdram_ba, output wire sdram_ras_n, sdram_cas_n, sdram_we_n,
    inout wire [31:0] sdram_dq
);
  retro_sdram_eye #(.Mode(1'b0)) u (.*);
endmodule
module retro_sdram_eye_snes (
    input wire clk, output wire led, uart_tx, input wire esp_sck, esp_cs_n,
    inout wire [3:0] esp_d, output wire esp_irq, sdram_clk, output wire [10:0] sdram_a,
    output wire [1:0] sdram_ba, output wire sdram_ras_n, sdram_cas_n, sdram_we_n,
    inout wire [31:0] sdram_dq
);
  retro_sdram_eye #(.Mode(1'b1)) u (.*);
endmodule
`default_nettype wire
`default_nettype none
// A/B: тот же MD-тест, регистры команд/адреса упакованы в IOB (constraints/sdram.xdc).
module retro_sdram_eye_md_iob (
    input wire clk, output wire led, uart_tx, input wire esp_sck, esp_cs_n,
    inout wire [3:0] esp_d, output wire esp_irq, sdram_clk, output wire [10:0] sdram_a,
    output wire [1:0] sdram_ba, output wire sdram_ras_n, sdram_cas_n, sdram_we_n,
    inout wire [31:0] sdram_dq
);
  retro_sdram_eye #(.Mode(1'b0)) u (.*);
endmodule
`default_nettype wire
`default_nettype none
module retro_sdram_eye_md_iob_dq (
    input wire clk, output wire led, uart_tx, input wire esp_sck, esp_cs_n,
    inout wire [3:0] esp_d, output wire esp_irq, sdram_clk, output wire [10:0] sdram_a,
    output wire [1:0] sdram_ba, output wire sdram_ras_n, sdram_cas_n, sdram_we_n,
    inout wire [31:0] sdram_dq
);
  retro_sdram_eye #(.Mode(1'b0)) u (.*);
endmodule
`default_nettype wire
