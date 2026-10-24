`default_nettype none

// Шина ESP для верха профиля: PLL 25 → 100 МГц, двунаправленные линии данных и profile_shell.
// Профиль получает такт шины, её сброс, регистры CSR и поток байтов (см. profile_shell).
module profile_bus #(
    parameter logic [15:0] ProfileId = 16'd0,
    parameter bit          UseIcap = 1'b0
) (
    input  wire        clk_25m,
    input  wire        esp_sck,
    input  wire        esp_cs_n,
    inout  wire  [3:0] esp_d,
    output wire        esp_irq,
    output wire        clk_bus,     // 100 МГц
    output wire        rst_bus,
    output wire        csr_we,
    output wire  [ 7:0] csr_waddr,
    output wire  [31:0] csr_wdata,
    output wire  [ 7:0] csr_raddr,
    input  wire  [31:0] csr_rdata,
    output wire        st_valid,
    output wire  [ 7:0] st_chan,
    output wire  [ 7:0] st_data,
    output wire  [31:0] pad,         // кнопки {пад 1, пад 0}, команда PAD (profile_shell)
    output wire        pad_stb
);
  wire fb, c100_raw, locked;
  PLLE2_BASE #(
      .CLKIN1_PERIOD(40.0), .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT(40), .CLKOUT0_DIVIDE(10)
  ) u_pll (
      .CLKIN1(clk_25m), .CLKFBIN(fb), .CLKFBOUT(fb), .CLKOUT0(c100_raw), .CLKOUT1(), .CLKOUT2(),
      .CLKOUT3(), .CLKOUT4(), .CLKOUT5(), .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0)
  );
  BUFG u_bufg (.I(c100_raw), .O(clk_bus));
  reset_sync u_rst (.clk(clk_bus), .rst_in(!locked), .rst_out(rst_bus));

  wire [3:0] d_in, d_out;
  wire d_oe;
  for (genvar i = 0; i < 4; i++) begin : g_io
    IOBUF u_io (.IO(esp_d[i]), .I(d_out[i]), .T(~d_oe), .O(d_in[i]));
  end

  profile_shell #(.ProfileId(ProfileId), .UseIcap(UseIcap)) u_shell (
      .clk(clk_bus), .rst(rst_bus), .esp_sck(esp_sck), .esp_cs_n(esp_cs_n), .d_in(d_in),
      .d_out(d_out), .d_oe(d_oe), .irq(esp_irq),
      .csr_we(csr_we), .csr_waddr(csr_waddr), .csr_wdata(csr_wdata), .csr_raddr(csr_raddr),
      .csr_rdata(csr_rdata), .st_valid(st_valid), .st_chan(st_chan), .st_data(st_data),
      .pad(pad), .pad_stb(pad_stb));

endmodule
