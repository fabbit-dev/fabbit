`default_nettype none

// Breadboard capture profile: P2 inputs, existing ESP link on P3. No SDRAM dependency.
module la_top #(
    parameter bit Ddr = 1'b0,
    parameter bit Serdes = 1'b0
) (
    input  wire        clk,
    output wire        led,
    output wire        uart_tx,
    output wire        phy_reset_n,
    input  wire        esp_sck,
    input  wire        esp_cs_n,
    inout  wire [ 3:0] esp_d,
    output wire        esp_irq,
    input  wire [15:0] probe
);
  wire clk_bus, clk_fast, rst_bus, csr_we;
  wire [7:0] csr_waddr, csr_raddr, rb_data;
  wire [23:0] rb_addr;
  wire [31:0] csr_wdata, csr_rdata;
  wire done;
  // reset_sync asserts asynchronously. BRAM enables must only depend on a clocked reset.
  logic rst_capture = 1'b1;
  always_ff @(posedge clk_bus) rst_capture <= rst_bus;
  assign phy_reset_n = 1'b0;
  assign uart_tx = 1'b1;
  assign led = !done;
  profile_bus #(.ProfileId(16'h4C41), .UseIcap(1'b1), .Readback(1'b1)) u_bus (
      .clk_25m(clk), .esp_sck(esp_sck), .esp_cs_n(esp_cs_n), .esp_d(esp_d), .esp_irq(esp_irq),
      .clk_bus(clk_bus), .rst_bus(rst_bus), .csr_we(csr_we), .csr_waddr(csr_waddr),
      .csr_wdata(csr_wdata), .csr_raddr(csr_raddr), .csr_rdata(csr_rdata),
      .st_valid(), .st_chan(), .st_data(), .pad(), .pad_stb(),
      .rb_addr(rb_addr), .rb_data(rb_data), .clk_fast(clk_fast));
  la_system #(.Ddr(Ddr), .Serdes(Serdes)) u_la (
      .clk(clk_bus), .clk_fast(clk_fast), .rst(rst_capture),
      .probe(probe), .csr_we(csr_we), .csr_waddr(csr_waddr),
      .csr_wdata(csr_wdata), .csr_raddr(csr_raddr), .csr_rdata(csr_rdata),
      .rb_addr(rb_addr), .rb_data(rb_data), .capture_done(done));
endmodule
