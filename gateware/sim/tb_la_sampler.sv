`default_nettype none
`timescale 1ns / 1ps

// Run against AMD UNISIM IDDR, not a hand-written model of the device primitive.
module tb_la_sampler;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [15:0] probe = 0;
  // Change every half-cycle, two ns away from either sampling edge.
  initial begin
    #2;
    forever #5 probe = probe + 16'd1;
  end
  wire valid_sdr, valid_ddr;
  wire [15:0] sdr;
  wire [31:0] ddr;
  la_sampler u_sdr (
      .clk(clk), .clk_fast(1'b0), .rst(rst), .probe(probe), .valid(valid_sdr), .samples(sdr));
  la_sampler #(.Ddr(1'b1)) u_ddr (
      .clk(clk), .clk_fast(1'b0), .rst(rst), .probe(probe), .valid(valid_ddr), .samples(ddr));
  logic [15:0] prior_rise = 0, older_rise = 0, prior_fall = 0, older_fall = 0;
  int checks = 0;
  always @(negedge clk) begin
    older_fall = prior_fall;
    prior_fall = probe;
  end
  always @(posedge clk) begin
    logic [15:0] expected_sdr, expected_rise, expected_fall;
    expected_sdr = prior_rise;
    expected_rise = older_rise;
    expected_fall = older_fall;
    older_rise = prior_rise;
    prior_rise = probe;
    #1;
    if (valid_sdr) begin
      if (sdr !== expected_sdr) $fatal(1, "SDR latency/order mismatch");
      checks++;
    end
    if (valid_ddr) begin
      if (ddr !== {expected_fall, expected_rise})
        $fatal(1, "IDDR Q-order mismatch got=%08x expected=%04x%04x",
               ddr, expected_fall, expected_rise);
      checks++;
    end
    if (rst && (valid_sdr || valid_ddr)) $fatal(1, "reset returned a valid sample");
  end
  initial begin
    #202 rst = 0;
    #1000 rst = 1;
    #40 rst = 0;
    #1000;
    if (checks < 300) $fatal(1, "insufficient sampling checks");
    $display("ok   UNISIM: SDR and IDDR chronological order, fixed latency, reset/startup");
    $finish;
  end
  initial begin
    #10us;
    $fatal(1, "TIMEOUT");
  end
endmodule
