`default_nettype none

// Тестовый профиль: оболочка (ID для ESP) + мигалка. Pattern 0: 2 Гц, 1: тройная вспышка.
// UART ПЛИС раз в секунду: "P <id>".
module blink_top #(
    parameter logic [15:0] ProfileId = 16'd1,
    parameter bit          Pattern = 1'b0
) (
    input  wire       clk,       // 25 МГц, K4
    output wire       led,
    output wire       uart_tx,
    input  wire       esp_sck,
    input  wire       esp_cs_n,
    inout  wire [3:0] esp_d,
    output wire       esp_irq
);
  wire c100, rst_bus;
  profile_bus #(.ProfileId(ProfileId)) u_bus (
      .clk_25m(clk), .esp_sck(esp_sck), .esp_cs_n(esp_cs_n), .esp_d(esp_d), .esp_irq(esp_irq),
      .clk_bus(c100), .rst_bus(rst_bus), .csr_we(), .csr_waddr(), .csr_wdata(), .csr_raddr(),
      .csr_rdata(32'd0), .st_valid(), .st_chan(), .st_data(), .pad(), .pad_stb(),
      .rb_addr(), .rb_data(8'd0), .clk_fast(), .bus_header(), .bus_command(),
      .bus_address(), .bus_write(), .bus_data(), .bus_end());

  logic [26:0] t = 27'd0;
  always_ff @(posedge c100) t <= (t == 27'd99_999_999) ? 27'd0 : t + 27'd1;
  // 0: 2 Гц; 1: три вспышки по 50 мс в начале секунды
  assign led = Pattern ? (t < 27'd30_000_000 && t[22]) : t[24];

  logic pr_start = 1'b0, pr_busy;
  uart_hexline #(.Div(868)) u_pr (
      .clk(c100), .start(pr_start), .tag("P"), .value({16'd0, ProfileId}), .busy(pr_busy),
      .tx(uart_tx)
  );
  always_ff @(posedge c100) pr_start <= (t == 27'd0);
endmodule
