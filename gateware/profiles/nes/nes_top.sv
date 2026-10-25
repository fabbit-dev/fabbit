`default_nettype none

// Профиль NES: ядро NESTang (core/, GPL-3) в оболочке Fabbit, вывод 640×480@60 по HDMI.
//
//   ESP ─quad SPI─ profile_bus (100 МГц) ─поток 0─ fifo_async ─ GameLoader ─┐
//                                                                         NES ─ nes_sdram ─ SDRAM
//   NES color/cycle/scanline ─ video_fb_scale (×2) ─ nes_palette ─ hdmi_tx      (64,3 МГц)
//   ESP PAD (profile_shell) ─ cdc_word ─ nes_pad (раскладка, турбо) ─ 4021 ядра
//
// Такты: шина 100 МГц (PLL), ядро 21,43 МГц и SDRAM 64,3 МГц (nes_clocks), видео 25,19 МГц
// (video_clocks). Между доменами только sync_bit, fifo_async и буфер кадра (ram_sdp).
//
// Регистры (CSR):
//   0 "FNES"
//   1 управление, только с ключом 0x4E53 ("NS") в [31:16]: бит 0 начать загрузку ROM (сброс
//     ядра и загрузчика, очистка FIFO), бит 1 сброс ядра
//   2 состояние: бит 0 идёт загрузка, бит 1 ROM загружен, бит 2 ошибка загрузчика
//   3 свободно в FIFO потока, байт (оценка снизу)
//   4 принято байт потока с начала загрузки
//   5 запись с ключом 0x4E53 в [31:16]: кнопки NES для отладки (A, B, Select, Start, Вверх, Вниз,
//     Влево, Вправо = биты 0..7), складываются с падом; чтение: [31:16] пад 0 (последний PAD),
//     [7:0] записанное
//   Кнопки игры приходят командой PAD (docs/bus-protocol.md), пад 0 = джойстик 1.
// Поток 0: файл .nes целиком (заголовок iNES и данные), не больше свободного места за кадр.
module nes_top (
    input  wire        clk,        // 25 МГц
    output wire        led,
    output wire        uart_tx,
    input  wire        esp_sck,
    input  wire        esp_cs_n,
    inout  wire  [3:0] esp_d,
    output wire        esp_irq,
    output wire  [3:0] hdmi_p,
    output wire  [3:0] hdmi_n,
    output wire        sdram_clk,
    output wire [10:0] sdram_a,
    output wire  [1:0] sdram_ba,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    inout  wire [31:0] sdram_dq
);
  import video_pkg::*;

  assign uart_tx = 1'b1;
  localparam int FifoDepth = 4096;

  // ---- шина ESP ----
  wire clk_bus, rst_bus, csr_we, st_valid, pad_stb;
  wire [31:0] pad;
  wire [7:0] csr_waddr, csr_raddr, st_chan, st_data;
  wire [31:0] csr_wdata;
  logic [31:0] csr_rdata;
  profile_bus #(.ProfileId(16'h0001), .UseIcap(1'b1)) u_bus (
      .clk_25m(clk), .esp_sck(esp_sck), .esp_cs_n(esp_cs_n), .esp_d(esp_d), .esp_irq(esp_irq),
      .clk_bus(clk_bus), .rst_bus(rst_bus), .csr_we(csr_we), .csr_waddr(csr_waddr),
      .csr_wdata(csr_wdata), .csr_raddr(csr_raddr), .csr_rdata(csr_rdata), .st_valid(st_valid),
      .st_chan(st_chan), .st_data(st_data), .pad(pad), .pad_stb(pad_stb));

  // ---- такты ядра и SDRAM ----
  wire nclk, fclk, sd_clk_int, nlocked, rst_nes;
  nes_clocks u_nesclk (
      .clk_25m(clk), .psclk(clk_bus), .psen(1'b0), .psincdec(1'b0), .psdone(),
      .clk(nclk), .fclk(fclk), .sdram_clk(sd_clk_int), .locked(nlocked));
  reset_sync u_rst_nes (.clk(nclk), .rst_in(!nlocked), .rst_out(rst_nes));

  // ---- регистры в домене шины ----
  localparam logic [15:0] CtrlKey = 16'h4E53;
  wire ctrl_we = csr_we && csr_waddr == 8'd1 && csr_wdata[31:16] == CtrlKey;
  logic load_tgl = 1'b0, reset_tgl = 1'b0, load_bus = 1'b0;
  logic [7:0] joy_bus = '0;
  logic [23:0] rx_bytes = '0;
  logic [15:0] pad_bus = '0;
  always_ff @(posedge clk_bus) begin
    load_bus <= 1'b0;
    if (ctrl_we && csr_wdata[0]) begin
      load_tgl <= ~load_tgl;
      load_bus <= 1'b1;
      rx_bytes <= '0;
    end
    if (ctrl_we && csr_wdata[1]) reset_tgl <= ~reset_tgl;
    if (csr_we && csr_waddr == 8'd5 && csr_wdata[31:16] == CtrlKey) joy_bus <= csr_wdata[7:0];
    if (st_valid && st_chan == 8'd0) rx_bytes <= rx_bytes + 1'b1;
    if (pad_stb) pad_bus <= pad[15:0];
    if (rst_bus) begin
      load_tgl  <= 1'b0;
      reset_tgl <= 1'b0;
      load_bus  <= 1'b0;
      joy_bus   <= '0;
      rx_bytes  <= '0;
      pad_bus   <= '0;
    end
  end

  // ---- переход в домен ядра ----
  wire load_s, reset_s, loading_s, done_s, fail_s;
  logic load_d = 1'b0, reset_d = 1'b0;
  sync_bit u_load (.clk(nclk), .d(load_tgl), .q(load_s));
  sync_bit u_rstq (.clk(nclk), .d(reset_tgl), .q(reset_s));
  always_ff @(posedge nclk) begin
    load_d  <= load_s;
    reset_d <= reset_s;
  end
  wire load_go = load_s ^ load_d;    // импульс: начать загрузку
  wire reset_go = reset_s ^ reset_d;
  // кнопки: слово пада целиком в домен ядра, раскладка и турбо по кадрам ядра
  wire [8:0] scanline;
  wire [31:0] pad_n;
  cdc_word #(.Width(32)) u_padx (
      .sclk(clk_bus), .stb(pad_stb), .d(pad), .dclk(nclk), .q(pad_n), .q_stb());
  wire [7:0] joy_dbg, joy_pad;
  for (genvar i = 0; i < 8; i++) begin : g_joy
    sync_bit u_j (.clk(nclk), .d(joy_bus[i]), .q(joy_dbg[i]));
  end
  logic frame_go = 1'b0;
  logic [8:0] line_d = '0;
  always_ff @(posedge nclk) begin
    line_d   <= scanline;
    frame_go <= scanline == 9'd0 && line_d != 9'd0;
  end
  nes_pad u_pad (.clk(nclk), .frame(frame_go), .pad(pad_n[15:0]), .joy(joy_pad));
  wire [7:0] joy = joy_pad | joy_dbg;

  // ---- поток ROM: шина → ядро ----
  wire [12:0] fifo_level;
  wire fifo_valid;
  wire [7:0] fifo_data;
  wire fifo_ready;
  fifo_async #(.Width(8), .Depth(FifoDepth)) u_fifo (
      .wclk(clk_bus), .wrst(rst_bus || load_bus), .in_valid(st_valid && st_chan == 8'd0),
      .in_ready(), .in_data(st_data), .wlevel(fifo_level),
      .rclk(nclk), .rrst(rst_nes || load_go), .out_valid(fifo_valid), .out_ready(fifo_ready),
      .out_data(fifo_data));

  // ---- система NES ----
  wire loading, loader_done, loader_fail, reset_nes, fb_we;
  wire [7:0] fb_x, fb_y;
  wire [8:0] fb_d;
  nes_system u_sys (
      .nclk(nclk), .fclk(fclk), .sdram_clk_in(sd_clk_int), .rst(rst_nes), .load_go(load_go),
      .reset_go(reset_go), .rom_valid(fifo_valid), .rom_ready(fifo_ready), .rom_data(fifo_data),
      .joy(joy), .loading(loading), .loader_done(loader_done), .loader_fail(loader_fail),
      .reset_nes(reset_nes), .fb_we(fb_we), .fb_x(fb_x), .fb_y(fb_y), .fb_d(fb_d), .sample(),
      .scanline(scanline), .sdram_clk(sdram_clk), .sdram_a(sdram_a), .sdram_ba(sdram_ba),
      .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
      .sdram_dq(sdram_dq));

  // ---- видео ----
  wire clk_pix, clk_5x, vlocked, rst_pix;
  video_clocks #(.Frac(1'b1)) u_vclk (
      .clk_25m(clk), .clk_pix(clk_pix), .clk_5x(clk_5x), .locked(vlocked), .rst_pix(rst_pix));

  vpx_t tim, scaled, colored;
  wire [8:0] idx;
  wire win;
  video_timing u_tim (.clk(clk_pix), .rst(rst_pix), .ce(1'b1), .px(tim));
  video_fb_scale #(.DataW(9), .SrcW(256), .SrcH(240), .Scale(2), .X0(64), .Y0(0)) u_fb (
      .wclk(nclk), .we(fb_we), .wx(fb_x), .wy(fb_y), .wdata(fb_d),
      .clk(clk_pix), .px_in(tim), .px_out(scaled), .idx(idx), .win(win));
  nes_palette u_pal (.clk(clk_pix), .px_in(scaled), .idx(idx), .win(win), .px_out(colored));
  hdmi_tx u_tx (.clk_pix(clk_pix), .clk_5x(clk_5x), .px(colored), .pad_p(hdmi_p), .pad_n(hdmi_n));

  // ---- состояние в домен шины ----
  sync_bit u_ld (.clk(clk_bus), .d(loading), .q(loading_s));
  sync_bit u_dn (.clk(clk_bus), .d(loader_done), .q(done_s));
  sync_bit u_fl (.clk(clk_bus), .d(loader_fail), .q(fail_s));

  always_comb
    case (csr_raddr)
      8'd0: csr_rdata = "FNES";
      8'd2: csr_rdata = {29'd0, fail_s, done_s, loading_s};
      8'd3: csr_rdata = fifo_level >= 13'(FifoDepth - 16) ? 32'd0 :
                       32'(FifoDepth - 16) - 32'(fifo_level);
      8'd4: csr_rdata = {8'd0, rx_bytes};
      8'd5: csr_rdata = {pad_bus, 8'd0, joy_bus};
      default: csr_rdata = '0;
    endcase

  // светодиод: горит, пока грузится ROM; мигает в такт кадрам, когда ядро работает
  logic [5:0] frames = '0;
  always_ff @(posedge nclk) if (frame_go) frames <= frames + 1'b1;
  assign led = loading || (!reset_nes && frames[5]);

endmodule
