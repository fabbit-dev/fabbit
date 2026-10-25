`default_nettype none
`timescale 1ns / 1ps

// Independent serial PRBS history, all 16 pins. Vendor SecureIP supplies ISERDESE2 behavior.
module tb_la_serdes_sampler;
  logic clk = 0, clk_fast = 1, rst = 1;
  always #5ns clk = ~clk;
  always #2500ps clk_fast = ~clk_fast;
  logic [15:0] probe = 16'hACE1;
  initial begin
    #1ns;
    forever begin
      #2500ps;
      probe = {probe[14:0], probe[15] ^ probe[13] ^ probe[12] ^ probe[10]};
    end
  end
  wire valid;
  wire [63:0] samples;
  la_sampler #(.Serdes(1'b1)) dut (
      .clk(clk), .clk_fast(clk_fast), .rst(rst), .probe(probe),
      .valid(valid), .samples(samples));
  logic [15:0] history[64];
  int serial_count = 0, last_start = -1, lag = -1, checks = 0;
  always @(posedge clk_fast or negedge clk_fast) begin
    history[serial_count % 64] = probe;
    serial_count++;
  end
  always @(posedge clk) begin
    #1ns;
    if (rst) begin
      if (valid) $fatal(1, "sampler valid during reset");
      last_start = -1;
      lag = -1;
    end else if (valid) begin
      int found, start;
      found = 0;
      start = -1;
      for (int i = serial_count-60; i <= serial_count-4; i++) begin
        if (i >= 0 && samples === {history[(i+3)%64], history[(i+2)%64],
                                  history[(i+1)%64], history[i%64]}) begin
          found++;
          start = i;
        end
      end
      if (found != 1) $fatal(1, "SERDES frame not a unique chronological PRBS window");
      if (last_start >= 0 && start != last_start+4) $fatal(1, "SERDES lost/repeated samples");
      if (lag >= 0 && serial_count-start != lag) $fatal(1, "SERDES latency changed");
      lag = serial_count-start;
      last_start = start;
      checks++;
    end
  end
  initial begin
    #220ns;
    rst = 0;
    #800ns;
    rst = 1;
    #30ns;
    rst = 0;
    #800ns;
    rst = 1;
    #40ns;
    rst = 0;
    #800ns;
    if (checks < 200) $fatal(1, "insufficient PRBS checks");
    $display("ok   SecureIP: 16-pin PRBS, oldest-first lanes, fixed latency, reset epochs");
    $display("ALL LA SAMPLER OK");
    $finish;
  end
  initial begin
    #10us;
    $fatal(1, "TIMEOUT");
  end
endmodule
