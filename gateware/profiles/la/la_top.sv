`default_nettype none

// Breadboard capture profile: P2 inputs, existing ESP link on P3. No SDRAM dependency.
module la_top
  import video_pkg::*;
#(
    parameter bit Ddr = 1'b0,
    parameter bit Serdes = 1'b0,
    parameter bit TestGenerator = 1'b0
) (
    input  wire        clk,
    output wire        led,
    output wire        uart_tx,
    output wire        phy_reset_n,
    input  wire        esp_sck,
    input  wire        esp_cs_n,
    inout  wire [ 3:0] esp_d,
    output wire        esp_irq,
    input  wire [15:0] probe,
    output wire [7:0] test_out,
    output wire [3:0] hdmi_p,
    output wire [3:0] hdmi_n
);
  wire clk_bus, clk_fast, rst_bus, csr_we;
  wire [7:0] csr_waddr, csr_raddr, rb_data;
  wire [23:0] rb_addr;
  wire [31:0] csr_wdata, csr_rdata, capture_rdata, profile_rdata;
  wire bus_header, bus_write, bus_end, shown;
  wire [7:0] bus_command, bus_data;
  wire [23:0] bus_address;
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
       .rb_addr(rb_addr), .rb_data(rb_data), .clk_fast(clk_fast),
       .bus_header(bus_header), .bus_command(bus_command), .bus_address(bus_address),
       .bus_write(bus_write), .bus_data(bus_data), .bus_end(bus_end));
  la_system #(.Ddr(Ddr), .Serdes(Serdes)) u_la (
      .clk(clk_bus), .clk_fast(clk_fast), .rst(rst_capture),
      .probe(probe), .csr_we(csr_we), .csr_waddr(csr_waddr),
      .csr_wdata(csr_wdata), .csr_raddr(csr_raddr), .csr_rdata(capture_rdata),
      .rb_addr(rb_addr), .rb_data(rb_data), .capture_done(done));

  if (TestGenerator) begin : g_loopback
    wire [31:0] generator_rdata;
    wire [7:0] generator_data;
    wire generator_enable;
    la_loopback u_generator (
        .clk(clk_bus), .rst(rst_capture), .csr_we(csr_we), .csr_waddr(csr_waddr),
        .csr_wdata(csr_wdata), .csr_raddr(csr_raddr), .csr_rdata(generator_rdata),
        .output_enable(generator_enable), .data(generator_data));
    assign profile_rdata = (csr_raddr >= 8'd32 && csr_raddr <= 8'd35) ?
                       generator_rdata : capture_rdata;
    assign test_out = generator_enable ? generator_data : 8'bzzzz_zzzz;
  end else begin : g_no_loopback
    assign test_out = 8'bzzzz_zzzz;
    assign profile_rdata = capture_rdata;
  end
  assign csr_rdata = (csr_raddr == 8'd64) ? "FBMV" :
                    (csr_raddr == 8'd65) ? {31'd0, shown} : profile_rdata;
  wire clk_pix, clk_5x, video_locked, rst_pix;
  video_clocks #(.Frac(1'b1)) u_vclk (
      .clk_25m(clk), .clk_pix(clk_pix), .clk_5x(clk_5x), .locked(video_locked), .rst_pix(rst_pix));
  vpx_t timing_px, screen_px;
  video_timing u_timing (.clk(clk_pix), .rst(rst_pix), .ce(1'b1), .px(timing_px));
  la_plane u_plane (
      .clk(clk_bus), .rst(rst_capture), .header(bus_header), .command(bus_command),
      .address(bus_address), .write_valid(bus_write), .data(bus_data), .frame_end(bus_end),
      .shown(shown), .clk_pix(clk_pix), .px_in(timing_px), .px_out(screen_px));
  hdmi_tx u_hdmi (
      .clk_pix(clk_pix), .clk_5x(clk_5x), .px(screen_px), .pad_p(hdmi_p), .pad_n(hdmi_n));
endmodule
