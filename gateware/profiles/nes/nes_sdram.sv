`default_nettype none

// Память NES на SDRAM i9+: контроллер sdram_nes из ядра (fclk = 3 × clk, слот 6 тактов fclk),
// опорный clkref и выход такта на микросхему через ODDR (UG471 «Clock Forwarding»).
// Порты A и B байтовые, 22 бита адреса: запрос — фронт oe/we в такте clk, где clkref = 1;
// данные чтения готовы через 3 такта clk (sdram_nes.v, заголовок).
//
// DQM у M12L64322A на модуле i9+ заземлены: побайтной записи нет, любая запись пишет все 4 байта
// слова. Поэтому каждый байт NES лежит в своём 32-битном слове (контроллер повторяет байт на
// все 4 линии и читает линию 0), а 22-битное пространство NES сжимается в 1M слов (2 банка):
//   PRG ROM  0x000000…  → слова 0x00000–0x7FFFF  (до 512 КБ)
//   CHR ROM  0x200000…  → слова 0x80000–0xBFFFF  (до 256 КБ)
//   ОЗУ      0x300000…  → слова 0xC0000–0xFFFFF: CIRAM 0x30…, WRAM 0x38…, PRG RAM 0x3C… (до 32 КБ),
//                         CHR RAM 0x3F8… (адреса cart.sv:1899-1900, mappers/*: prg_ram, chr_aout)
// Remap = 0: адрес порта сразу номер слова (addr[19:0]) — для теста всей памяти.
module nes_sdram #(
    parameter bit Remap = 1'b1,
    parameter bit SplitDq = 1'b0
) (
    input  wire        clk,         // 21,429 МГц
    input  wire        fclk,        // 3 × clk, синфазно
    input  wire        sdram_clk,   // fclk со сдвигом фазы
    input  wire        rst,         // домен clk
    input  wire        clkref_sync, // импульс: начать окно clkref = 1 (конец загрузки ROM)
    output logic       clkref = 1'b0,
    output wire        busy,        // инициализация SDRAM
    input  wire [21:0] addr_a,
    input  wire        oe_a,
    input  wire        we_a,
    input  wire  [7:0] din_a,
    output wire  [7:0] dout_a,
    input  wire [21:0] addr_b,
    input  wire        oe_b,
    input  wire        we_b,
    input  wire  [7:0] din_b,
    output wire  [7:0] dout_b,
    // микросхема
    output wire        sd_clk,
    output wire [10:0] sd_a,
    output wire  [1:0] sd_ba,
    output wire        sd_ras_n,
    output wire        sd_cas_n,
    output wire        sd_we_n,
    inout  wire [31:0] sd_dq,
    input wire [31:0] dq_input,
    output wire [31:0] dq_output,
    output wire dq_drive
);
  always_ff @(posedge clk)
    if (rst || clkref_sync) clkref <= 1'b1;
    else clkref <= ~clkref;

  wire rstn_f;
  sync_bit #(.Init(1'b0)) u_rst (.clk(fclk), .d(!rst), .q(rstn_f));

  function automatic logic [21:0] word(input logic [21:0] a);
    logic [19:0] w;
    if (!Remap) w = a[19:0];
    else if (!a[21]) w = {1'b0, a[18:0]};
    else if (!a[20]) w = {2'b10, a[17:0]};
    else w = {2'b11, a[19:18], a[15:0]};
    return {w, 2'b00};  // линия байта 0
  endfunction

  wire [3:0] dqm_unused;
  if (SplitDq) begin : g_split
  retro_nes_sdram_core #(.FREQ(64_286_000)) u_ctl (
      .clk(fclk), .resetn(rstn_f), .clkref(clkref), .busy(busy),
      .dq_input(dq_input), .dq_output(dq_output), .dq_drive(dq_drive),
      .SDRAM_A(sd_a), .SDRAM_DQM(dqm_unused), .SDRAM_BA(sd_ba),
      .SDRAM_nCS(), .SDRAM_nWE(sd_we_n), .SDRAM_nRAS(sd_ras_n), .SDRAM_nCAS(sd_cas_n),
      .SDRAM_CKE(),
      .addrA(word(addr_a)), .weA(we_a), .dinA(din_a), .oeA(oe_a), .doutA(dout_a),
      .addrB(word(addr_b)), .weB(we_b), .dinB(din_b), .oeB(oe_b), .doutB(dout_b),
      .rv_addr(20'd0), .rv_din(16'd0), .rv_ds(2'b00), .rv_dout(), .rv_req(1'b0),
      .rv_req_ack(), .rv_we(1'b0));
  end else begin : g_legacy
  assign dq_output=0;
  assign dq_drive=0;
  sdram_nes #(.FREQ(64_286_000)) u_ctl (
      .clk(fclk), .resetn(rstn_f), .clkref(clkref), .busy(busy),
      .SDRAM_DQ(sd_dq), .SDRAM_A(sd_a), .SDRAM_DQM(dqm_unused), .SDRAM_BA(sd_ba),
      .SDRAM_nCS(), .SDRAM_nWE(sd_we_n), .SDRAM_nRAS(sd_ras_n), .SDRAM_nCAS(sd_cas_n),
      .SDRAM_CKE(),
      .addrA(word(addr_a)), .weA(we_a), .dinA(din_a), .oeA(oe_a), .doutA(dout_a),
      .addrB(word(addr_b)), .weB(we_b), .dinB(din_b), .oeB(oe_b), .doutB(dout_b),
      .rv_addr(20'd0), .rv_din(16'd0), .rv_ds(2'b00), .rv_dout(), .rv_req(1'b0), .rv_req_ack(),
      .rv_we(1'b0)
  );
  end

  ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .SRTYPE("SYNC")) u_ck (
      .Q(sd_clk), .C(sdram_clk), .CE(1'b1), .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0));

endmodule
