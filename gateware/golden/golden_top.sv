`default_nettype none

// Golden-образ Fabbit (адрес 0 флеша): приём команд ESP по quad SPI, запись слотов, IPROG,
// HDMI 640×480@60 с плоскостью меню (osd_plane): до первой команды ESP на экране логотип.
// LED: короткая вспышка раз в 2 с. UART (R3): "B <BOOTSTS>" при старте, "C <cmd,err>" на кадр.
module golden_top
  import video_pkg::*;
(
    input  wire       clk,       // 25 МГц, K4
    output wire       led,
    output wire       uart_tx,
    input  wire       esp_sck,
    input  wire       esp_cs_n,
    inout  wire [3:0] esp_d,
    output wire       esp_irq,   // 1: golden свободен (флеш, ICAP и заливка плоскости)
    output wire       flash_cs_n,
    output wire       flash_mosi,
    input  wire       flash_miso,
    output wire       flash_wp_n,
    output wire       flash_hold_n,
    output wire [3:0] hdmi_p,
    output wire [3:0] hdmi_n
);
  // 25 -> 100 МГц
  logic clk_fb, clk100_raw, clk100, locked;
  PLLE2_BASE #(
      .CLKIN1_PERIOD (40.0),
      .DIVCLK_DIVIDE (1),
      .CLKFBOUT_MULT (40),
      .CLKOUT0_DIVIDE(10)
  ) u_pll (
      .CLKIN1  (clk),
      .CLKFBIN (clk_fb),
      .CLKFBOUT(clk_fb),
      .CLKOUT0 (clk100_raw),
      .CLKOUT1 (),
      .CLKOUT2 (),
      .CLKOUT3 (),
      .CLKOUT4 (),
      .CLKOUT5 (),
      .LOCKED  (locked),
      .PWRDWN  (1'b0),
      .RST     (1'b0)
  );
  BUFG u_bufg (
      .I(clk100_raw),
      .O(clk100)
  );

  // линии данных
  logic [3:0] d_in, d_out;
  logic       d_oe;
  for (genvar i = 0; i < 4; i++) begin : g_io
    IOBUF u_io (
        .IO(esp_d[i]),
        .I (d_out[i]),
        .T (~d_oe),
        .O (d_in[i])
    );
  end

  logic        hdr_valid, wr_valid, rd_req, frame_end;
  logic [ 7:0] cmd, wr_data, rd_data;
  logic [23:0] addr;
  logic [7:0] rd_start;
  logic       la_arm, la_busy, la_tx, pr_tx;
  logic       rd_fall;
  qspi_slave u_qspi (
      .clk      (clk100),
      .rd_start (rd_start),
      .rd_fall  (rd_fall),
      .sck      (esp_sck),
      .cs_n     (esp_cs_n),
      .d_in     (d_in),
      .d_out    (d_out),
      .d_oe     (d_oe),
      .hdr_valid(hdr_valid),
      .cmd      (cmd),
      .addr     (addr),
      .wr_valid (wr_valid),
      .wr_data  (wr_data),
      .rd_req   (rd_req),
      .rd_data  (rd_data),
      .frame_end(frame_end)
  );

  logic       busy, dbg_valid, osd_busy, osd_shown;
  logic [7:0] err, dbg_cmd;
  logic [31:0] bootsts;
  logic [15:0] frames;
  golden_core u_core (
      .clk          (clk100),
      .hdr_valid    (hdr_valid),
      .cmd          (cmd),
      .addr         (addr),
      .wr_valid     (wr_valid),
      .wr_data      (wr_data),
      .rd_req       (rd_req),
      .rd_data      (rd_data),
      .frame_end    (frame_end),
      .osd_busy     (osd_busy),
      .osd_shown    (osd_shown),
      .frames       (frames),
      .busy         (busy),
      .err          (err),
      .boot_status  (bootsts),
      .dbg_cmd      (dbg_cmd),
      .rd_start     (rd_start),
      .rd_fall      (rd_fall),
      .la_arm       (la_arm),
      .dbg_cmd_valid(dbg_valid),
      .flash_cs_n   (flash_cs_n),
      .flash_mosi   (flash_mosi),
      .flash_miso   (flash_miso),
      .flash_wp_n   (flash_wp_n),
      .flash_hold_n (flash_hold_n)
  );
  assign esp_irq = ~(busy || osd_busy);  // заливка плоскости тоже держит IRQ в 0

  // видео: развёртка → плоскость меню → HDMI
  wire clk_pix, clk_5x, vlocked, rst_pix;
  video_clocks #(.Frac(1'b1)) u_vclk (
      .clk_25m(clk), .clk_pix(clk_pix), .clk_5x(clk_5x), .locked(vlocked), .rst_pix(rst_pix));
  vpx_t tim, osd;
  video_timing u_tim (.clk(clk_pix), .rst(rst_pix), .ce(1'b1), .px(tim));
  osd_plane u_osd (
      .clk(clk100), .hdr_valid(hdr_valid), .cmd(cmd), .addr(addr), .wr_valid(wr_valid),
      .wr_data(wr_data), .frame_end(frame_end), .busy(osd_busy), .shown(osd_shown), .frames(frames),
      .clk_pix(clk_pix), .px_in(tim), .px_out(osd));
  hdmi_tx u_tx (.clk_pix(clk_pix), .clk_5x(clk_5x), .px(osd), .pad_p(hdmi_p), .pad_n(hdmi_n));

  // LED: вспышка 80 мс раз в ~2.7 с
  logic [27:0] blink = 28'd0;
  always_ff @(posedge clk100) blink <= blink + 28'd1;
  assign led = (blink[27:23] == 5'd0);

  // UART: B при старте, затем C на каждый кадр (если UART свободен)
  logic        pr_start = 1'b0, pr_busy, said_boot = 1'b0;
  logic [ 7:0] pr_tag = "B";
  logic [31:0] pr_val = 32'd0;
  logic [27:0] t0 = 28'd0;
  logic        dbg_d = 1'b0;  // err обновляется вместе с dbg_valid: печатаем на такт позже
  always_ff @(posedge clk100) dbg_d <= dbg_valid;
  uart_hexline #(
      .Div(868)
  ) u_pr (
      .clk  (clk100),
      .start(pr_start),
      .tag  (pr_tag),
      .value(pr_val),
      .busy (pr_busy),
      .tx   (pr_tx)
  );

  // отладочный анализатор шины: биты 0 SCK, 1 CS#, 2..5 IO0..IO3 (на выводах), 6 d_oe
  la_capture u_la (
      .clk  (clk100),
      .arm  (la_arm),
      .probe({1'b0, d_oe, d_in, esp_cs_n, esp_sck}),
      .busy (la_busy),
      .tx   (la_tx)
  );
  assign uart_tx = la_busy ? la_tx : pr_tx;
  always_ff @(posedge clk100) begin
    pr_start <= 1'b0;
    if (!said_boot) begin
      t0 <= t0 + 28'd1;
      if (t0 == 28'd10_000_000 && locked) begin  // 100 мс: BOOTSTS уже прочитан
        pr_tag    <= "B";
        pr_val    <= bootsts;
        pr_start  <= 1'b1;
        said_boot <= 1'b1;
      end
    end else if (dbg_d && !pr_busy) begin
      pr_tag   <= "C";
      pr_val   <= {dbg_cmd, 16'd0, err};
      pr_start <= 1'b1;
    end
  end
endmodule
