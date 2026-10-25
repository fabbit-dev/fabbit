`default_nettype none
`timescale 1ns / 1ps

// Physical double-edge stimulus -> real UNISIM IDDR -> decimator -> trigger/ring -> byte readout.
module tb_la_ddr #(
    parameter bit Serdes = 1'b0,
    localparam int K = Serdes ? 4 : 2,
    localparam int Capacity = 128-K,
    localparam realtime Step = Serdes ? 2.5 : 5.0
);
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic clk_fast = 1;
  always #2500ps clk_fast = ~clk_fast;
  logic [15:0] generator = 0;
  wire [15:0] probe;
  logic pulse_mode = 0;
  logic [15:0] pulse = 0;
  assign probe = pulse_mode ? pulse : generator;
  initial begin
    #2;
    forever #(Step) generator = generator + 16'd1;
  end
  logic we = 0;
  logic [7:0] waddr = 0, raddr = 0;
  logic [31:0] wdata = 0;
  wire [31:0] rdata;
  logic [23:0] rb_addr = 0;
  wire [7:0] rb_data;
  wire done;
  la_system #(.Ddr(1'b1), .Serdes(Serdes), .Depth(128)) dut (
      .clk(clk), .clk_fast(clk_fast), .rst(rst),
      .probe(probe), .csr_we(we), .csr_waddr(waddr), .csr_wdata(wdata),
      .csr_raddr(raddr), .csr_rdata(rdata), .rb_addr(rb_addr), .rb_data(rb_data),
      .capture_done(done));

  task automatic tick();
    @(posedge clk);
    #1;
    @(negedge clk);
  endtask
  task automatic write_csr(input int address, input logic [31:0] data);
    waddr = 8'(address);
    wdata = data;
    we = 1;
    tick();
    we = 0;
  endtask
  task automatic read_sample(input int index, output logic [15:0] sample_value);
    rb_addr = 24'(index*2);
    tick();
    sample_value[7:0] = rb_data;
    rb_addr = 24'(index*2+1);
    tick();
    sample_value[15:8] = rb_data;
  endtask
  task automatic wait_done();
    for (int i = 0; i < 10000 && !done; i++) tick();
    if (!done) $fatal(1, "capture did not finish");
  endtask

  // Compare the optimized frame countdown against an independent scalar sample loop,
  // including 32-bit divisors and counter rollover, without waiting billions of clocks.
  task automatic check_decimation();
    logic [31:0] period, left, expected_left;
    logic [15:0] count_in, expected_count;
    logic [16*K-1:0] probes, packed_in, data_in, expected_packed, expected_data;
    logic [$clog2(K)-1:0] fill_in, expected_fill;
    logic use_counter, expected_valid;
    logic [32+16+16*K+$clog2(K)+16*K:0] got, expected;
    for (int trial = 0; trial < 2000; trial++) begin
      period = (trial < 1000) ? 32'(trial % 32) : $urandom;
      left = (trial < 1000) ? 32'(trial % (int'(period)+1)) :
             ((trial % 2 == 0) ? 32'(trial % K) : $urandom);
      count_in = 16'($urandom);
      fill_in = $clog2(K)'($urandom);
      for (int j = 0; j < K; j++) begin
        probes[j*16+:16] = 16'($urandom);
        packed_in[j*16+:16] = 16'($urandom);
        data_in[j*16+:16] = 16'($urandom);
      end
      use_counter = 1'($urandom);
      expected_left = left;
      expected_count = count_in;
      expected_fill = fill_in;
      expected_packed = packed_in;
      expected_data = data_in;
      expected_valid = 0;
      for (int j = 0; j < K; j++) begin
        if (expected_left == 0) begin
          expected_packed[16*int'(expected_fill)+:16] =
              use_counter ? expected_count : probes[j*16+:16];
          if (expected_fill == $clog2(K)'(K-1)) begin
            expected_data = expected_packed;
            expected_valid = 1;
            expected_fill = 0;
          end else expected_fill++;
          expected_count++;
          expected_left = period;
        end else expected_left--;
      end
      expected = {expected_left, expected_count, expected_packed, expected_fill,
                  expected_data, expected_valid};
      got = dut.decimate(left, period, period-(K-1), count_in, packed_in, data_in,
                         probes, fill_in, use_counter);
      if (got !== expected) $fatal(1, "decimation scalar mismatch trial=%0d", trial);
    end
    $display("ok   K=%0d: 2000 scalar decimator comparisons, full-width divisors", K);
  endtask

  initial begin
    logic [15:0] first, sample_value;
    #200;
    tick();
    rst = 0;
    repeat (8) tick();
    check_decimation();
    raddr = 4;
    #1;
    if (rdata != K*100_000_000) $fatal(1, "nominal sample rate");
    raddr = 3;
    #1;
    if (rdata != Capacity) $fatal(1, "guard-frame capacity");
    // Full capacity, odd head/tail and odd divisors: sample intervals must stay uniform.
    for (int divider = 0; divider < 18; divider++) begin
      write_csr(5, 32'(Capacity-1));
      write_csr(6, 38);
      write_csr(7, 32'(divider));
      write_csr(8, 0);
      write_csr(16, 0);
      write_csr(1, 32'h4C41_0001);
      wait_done();
      raddr = 13;
      #1;
      if (rdata != Capacity-1-38) $fatal(1, "pretrigger index");
      read_sample(0, first);
      for (int i = 0; i < Capacity-1; i++) begin
        read_sample(i, sample_value);
        if (sample_value !== 16'(int'(first) + i*(divider+1)))
          $fatal(1, "divider=%0d sample[%0d]=%0d first=%0d", divider, i, sample_value, first);
      end
      rb_addr = 24'((Capacity-1)*2);
      tick();
      if (rb_data != 0) $fatal(1, "DDR read beyond capture");
    end
    // Counter: trigger at every lane, with arbitrary pre/post alignment.
    for (int lane = 0; lane < K; lane++) begin
      for (int post = 1; post < 8; post++) begin
        write_csr(5, 32'(Capacity));
        write_csr(6, 32'(post));
        write_csr(7, 0);
        write_csr(8, 65535);
        write_csr(9, 32'(1000+lane));
        write_csr(16, 1);
        write_csr(1, 32'h4C41_0001);
        wait_done();
        for (int i = 0; i < Capacity; i++) begin
          read_sample(i, sample_value);
          if (sample_value !== 16'(1000+lane-(Capacity-post)+i))
            $fatal(1, "DDR trigger lane=%0d post=%0d sample[%0d]", lane, post, i);
        end
      end
    end
    // One-sample pulse: rising edge at every position of the raw sampler frame.
    for (int lane = 0; lane < K; lane++) begin
      write_csr(5, 9);
      write_csr(6, 5);
      write_csr(7, 0);
      write_csr(8, 0);
      write_csr(10, 1);
      write_csr(16, 0);
      pulse_mode = 1;
      pulse = 0;
      repeat (8) tick();
      write_csr(1, 32'h4C41_0001);
      repeat (8) tick();
      // tick returns on a fabric falling edge; choose each raw sampling phase in turn.
      #1ns;
      repeat (lane) #(Step);
      pulse = 1;
      #(Step) pulse = 0;
      wait_done();
      for (int i = 0; i < 9; i++) begin
        read_sample(i, sample_value);
        if (sample_value !== ((i == 4) ? 16'd1 : 16'd0))
          $fatal(1, "physical half-cycle pulse lane=%0d sample[%0d]=%0d", lane, i, sample_value);
      end
    end
    $display("ok   UNISIM K=%0d: order, divisors 1..18, odd windows, full ring, lanes", K);
    $display("ALL LA DATAPATH OK");
    $finish;
  end
  initial begin
    #2ms;
    $fatal(1, "TIMEOUT");
  end
endmodule
