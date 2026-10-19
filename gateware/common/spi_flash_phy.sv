`default_nettype none

// SPI x1, режим 0, к конфигурационному флешу. SCK идёт на CCLK (L12) через STARTUPE2.USRCCLKO.
// После конфигурации первые 3 такта USRCCLKO теряются (UG470): модуль даёт их сам при CS=1.
// Частота SCK = f_clk / (2 * Half).
module spi_flash_phy #(
    parameter int Half = 2
) (
    input  wire       clk,
    input  wire       cs_req,    // 1: держать CS# в 0
    input  wire       start,     // передать байт tx, принять rx
    input  wire [7:0] tx,
    output logic [7:0] rx,
    output wire       busy,
    output wire       ready,     // начальные такты отданы
    output wire       flash_cs_n,
    output wire       flash_mosi,
    input  wire       flash_miso,
    output wire       flash_wp_n,
    output wire       flash_hold_n
);
  logic       sck = 1'b0;
  logic [7:0] sh = 8'd0;
  logic [3:0] nbit = 4'd0;
  logic [7:0] div = 8'd0;
  logic [3:0] init_clk = 4'd8;  // такты для переключения CCLK на USRCCLKO
  logic [15:0] init_wait = 16'd0;  // пауза после старта до этих тактов

  assign flash_cs_n   = ~(cs_req && init_clk == 0);
  assign flash_mosi   = sh[7];
  assign flash_wp_n   = 1'b1;
  assign flash_hold_n = 1'b1;
  assign busy         = (nbit != 0) || (init_clk != 0);
  assign ready        = (init_clk == 0);

  STARTUPE2 #(
      .PROG_USR("FALSE"),
      .SIM_CCLK_FREQ(0.0)
  ) u_startup (
      .CFGCLK   (),
      .CFGMCLK  (),
      .EOS      (),
      .PREQ     (),
      .CLK      (1'b0),
      .GSR      (1'b0),
      .GTS      (1'b0),
      .KEYCLEARB(1'b1),
      .PACK     (1'b0),
      .USRCCLKO (sck),
      .USRCCLKTS(1'b0),
      .USRDONEO (1'b1),
      .USRDONETS(1'b1)
  );

  always_ff @(posedge clk) begin
    if (init_wait != 16'hFFFF) init_wait <= init_wait + 16'd1;
    else if (init_clk != 0) begin
      if (div == Half - 1) begin
        div <= 8'd0;
        sck <= ~sck;
        if (sck) init_clk <= init_clk - 4'd1;
      end else div <= div + 8'd1;
    end else if (nbit != 0) begin
      if (div == Half - 1) begin
        div <= 8'd0;
        if (!sck) begin
          sck   <= 1'b1;
          rx    <= {rx[6:0], flash_miso};
        end else begin
          sck  <= 1'b0;
          sh   <= {sh[6:0], 1'b0};
          nbit <= nbit - 4'd1;
        end
      end else div <= div + 8'd1;
    end else if (start) begin
      sh   <= tx;
      nbit <= 4'd8;
      div  <= 8'd0;
    end
  end
endmodule
