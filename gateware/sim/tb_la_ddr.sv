`default_nettype none
`timescale 1ns / 1ps

// Physical double-edge stimulus -> real UNISIM IDDR -> decimator -> trigger/ring -> byte readout.
module tb_la_ddr;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [15:0] generator = 0;
  wire [15:0] probe;
  logic pulse_mode = 0;
  logic [15:0] pulse = 0;
  assign probe = pulse_mode ? pulse : generator;
  initial begin
    #2;
    forever #5 generator = generator + 16'd1;
  end
  logic we = 0;
  logic [7:0] waddr = 0, raddr = 0;
  logic [31:0] wdata = 0;
  wire [31:0] rdata;
  logic [23:0] rb_addr = 0;
  wire [7:0] rb_data;
  wire done;
  la_system #(.Ddr(1'b1), .Depth(128)) dut (
      .clk(clk), .rst(rst), .probe(probe), .csr_we(we), .csr_waddr(waddr), .csr_wdata(wdata),
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
    for (int i = 0; i < 2000 && !done; i++) tick();
    if (!done) $fatal(1, "capture did not finish");
  endtask

  initial begin
    logic [15:0] first, sample_value;
    #200;
    tick();
    rst = 0;
    repeat (8) tick();
    raddr = 4;
    #1;
    if (rdata != 200_000_000) $fatal(1, "DDR nominal sample rate");
    raddr = 3;
    #1;
    if (rdata != 126) $fatal(1, "DDR guard-frame capacity");
    // Full capacity, odd head/tail and odd divisors: sample intervals must stay uniform.
    for (int divider = 0; divider < 6; divider++) begin
      write_csr(5, 125);
      write_csr(6, 38);
      write_csr(7, 32'(divider));
      write_csr(8, 0);
      write_csr(16, 0);
      write_csr(1, 32'h4C41_0001);
      wait_done();
      raddr = 13;
      #1;
      if (rdata != 87) $fatal(1, "DDR pretrigger index");
      read_sample(0, first);
      for (int i = 0; i < 125; i++) begin
        read_sample(i, sample_value);
        if (sample_value !== 16'(int'(first) + i*(divider+1)))
          $fatal(1, "divider=%0d sample[%0d]=%0d first=%0d", divider, i, sample_value, first);
      end
      rb_addr = 250;
      tick();
      if (rb_data != 0) $fatal(1, "DDR read beyond capture");
    end
    // Counter: trigger at either lane, both sides of a frame, with arbitrary pre/post parity.
    for (int lane = 0; lane < 2; lane++) begin
      for (int post = 1; post < 8; post++) begin
        write_csr(5, 126);
        write_csr(6, 32'(post));
        write_csr(7, 0);
        write_csr(8, 65535);
        write_csr(9, 32'(1000+lane));
        write_csr(16, 1);
        write_csr(1, 32'h4C41_0001);
        wait_done();
        for (int i = 0; i < 126; i++) begin
          read_sample(i, sample_value);
          if (sample_value !== 16'(1000+lane-(126-post)+i))
            $fatal(1, "DDR trigger lane=%0d post=%0d sample[%0d]", lane, post, i);
        end
      end
    end
    // One-half-cycle pulse: rising edge at either physical sampling edge. Raw payload must
    // contain the pulse once, including a trigger in the second lane of the DDR pair.
    for (int lane = 0; lane < 2; lane++) begin
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
      // tick returns on a falling edge: offset 2ns for rising, 7ns for falling.
      if (lane == 0) #2;
      else #7;
      pulse = 1;
      #5 pulse = 0;
      wait_done();
      for (int i = 0; i < 9; i++) begin
        read_sample(i, sample_value);
        if (sample_value !== ((i == 4) ? 16'd1 : 16'd0))
          $fatal(1, "physical half-cycle pulse lane=%0d sample[%0d]=%0d", lane, i, sample_value);
      end
    end
    $display("ok   UNISIM DDR: sample order, divisors 1..6, odd windows, full ring, lanes");
    $finish;
  end
  initial begin
    #2ms;
    $fatal(1, "TIMEOUT");
  end
endmodule
