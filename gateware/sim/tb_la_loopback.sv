`default_nettype none
`timescale 1ns / 1ps

// Generator output pads -> simulated external wires -> real capture input sampler.
// With Serdes=1 run in xsim/SecureIP; SDR regression also runs in Verilator.
module tb_la_loopback #(
    parameter bit Serdes = 1'b0
);
  logic clk = 0, clk_fast = 1, rst = 1;
  always #5ns clk = ~clk;
  always #2500ps clk_fast = ~clk_fast;
  logic csr_we = 0;
  logic [7:0] csr_waddr = 0, csr_raddr = 0;
  logic [31:0] csr_wdata = 0;
  wire [31:0] generator_rdata, capture_rdata;
  wire generator_enable;
  wire [7:0] generator_data;
  wire [7:0] pads;
  assign pads = generator_enable ? generator_data : 8'bzzzz_zzzz;
  // A wire delay is not an SI model. It separates generated edges from sampling edges.
  wire [7:0] looped;
  assign #1ns looped = pads;
  logic upper_group = 0;
  wire [15:0] probe = upper_group ? {looped, 8'd0} : {8'd0, looped};
  wire [7:0] rb_data;
  logic [23:0] rb_addr = 0;
  wire done;
  la_loopback generator (
      .clk(clk), .rst(rst), .csr_we(csr_we), .csr_waddr(csr_waddr), .csr_wdata(csr_wdata),
      .csr_raddr(csr_raddr), .csr_rdata(generator_rdata),
      .output_enable(generator_enable), .data(generator_data));
  la_system #(.Depth(2048), .Serdes(Serdes)) capture (
      .clk(clk), .clk_fast(clk_fast), .rst(rst), .probe(probe), .csr_we(csr_we),
      .csr_waddr(csr_waddr), .csr_wdata(csr_wdata), .csr_raddr(csr_raddr),
      .csr_rdata(capture_rdata), .rb_addr(rb_addr), .rb_data(rb_data), .capture_done(done));

  task automatic tick();
    @(posedge clk);
    #2ns;
    @(negedge clk);
  endtask
  task automatic write_csr(input int address, input logic [31:0] data);
    csr_waddr = 8'(address);
    csr_wdata = data;
    csr_we = 1;
    tick();
    csr_we = 0;
  endtask
  task automatic read_sample(input int index, output logic [15:0] data);
    rb_addr = 24'(index*2);
    tick();
    data[7:0] = rb_data;
    rb_addr = 24'(index*2+1);
    tick();
    data[15:8] = rb_data;
  endtask
  task automatic frozen();
    for (int n = 0; n < 100000 && !done; n++) tick();
    if (!done) $fatal(1, "loopback capture timed out");
  endtask
  function automatic logic [7:0] prbs(input logic [7:0] value);
    return {value[6:0], value[7] ^ value[5] ^ value[4] ^ value[3]};
  endfunction

  initial begin
    logic [15:0] sample_value;
    logic [7:0] expected, seed;
    repeat (20) tick();
    if (generator_enable) $fatal(1, "generator drives during reset");
    if (Serdes && pads !== 8'bzzzz_zzzz) $fatal(1, "reset outputs are not Hi-Z");
    rst = 0;
    repeat (8) tick();
    if (generator_enable) $fatal(1, "generator enabled after reset");
    csr_raddr = 35;
    #1ns;
    if (generator_rdata != "FBLG") $fatal(1, "generator ID");
    write_csr(32, 32'hDEAD_0007);
    if (generator_enable) $fatal(1, "bad key enables generator");
    write_csr(34, 32'h5A);
    write_csr(32, 32'h4C47_0001);
    if (!generator_enable || pads !== 8'h5A) $fatal(1, "static output");
    write_csr(34, 32'hA5);
    repeat (150) tick();
    if (pads !== 8'h5A) $fatal(1, "shadow value changes active static output");
    write_csr(32, 32'h4C47_0000);
    if (generator_enable) $fatal(1, "disable output");
    if (Serdes && pads !== 8'bzzzz_zzzz) $fatal(1, "disabled outputs are not Hi-Z");
    // Four modes, minimum period clamp and exact symbol timing.
    for (int mode = 1; mode < 4; mode++) begin
      write_csr(33, 0);  // clamp to 100 clocks, never a fast accidental drive
      write_csr(34, 0);  // PRBS zero seed must map to a nonzero fallback
      write_csr(32, 32'h4C47_0001 | (32'(mode) << 1));
      expected = (mode == 1) ? 8'd0 : ((mode == 2) ? 8'd1 : 8'hA5);
      seed = expected;
      for (int symbol = 0; symbol < 256; symbol++) begin
        if (pads !== expected) $fatal(1, "mode=%0d symbol=%0d", mode, symbol);
        for (int cycle = 0; cycle < 99; cycle++) begin
          tick();
          if (pads !== expected) $fatal(1, "symbol duration too short");
        end
        tick();
        case (mode)
          1: expected = expected + 8'd1;
          2: expected = ((symbol+1) % 16 < 8) ?
                         (8'd1 << ((symbol+1) % 8)) : ~(8'd1 << ((symbol+1) % 8));
          3: expected = prbs(expected);
          default: ;
        endcase
        if (mode == 3 && symbol < 254 && expected == seed) $fatal(1, "PRBS short cycle");
        if (mode == 3 && symbol == 254 && expected != seed) $fatal(1, "PRBS period not 255");
      end
      write_csr(32, 32'h4C47_0000);
    end
    write_csr(33, 125);
    write_csr(32, 32'h4C47_0003);
    write_csr(33, 1000);
    write_csr(34, 255);
    write_csr(32, 32'hDEAD_0000);
    // The three CSR writes took three clocks. New shadow settings and a bad key must not
    // affect the active counter or its 125-clock symbol period.
    repeat (121) tick();
    if (!generator_enable || generator_data != 0) $fatal(1, "active period/shadow config changed");
    tick();
    if (generator_data != 1) $fatal(1, "non-minimum period timing");
    write_csr(32, 32'h4C47_0000);
    // Changing one output at a time identifies crossed/shorted wires. Test both input banks
    // using two placements of the same eight simulated wires, without an internal bypass.
    for (int group = 0; group < 2; group++) begin
      upper_group = 1'(group);
      for (int pattern = 0; pattern < 18; pattern++) begin
        logic [7:0] value;
        value = (pattern < 8) ? (8'd1 << pattern) :
                (pattern < 16) ? ~(8'd1 << (pattern-8)) : ((pattern == 16) ? 8'd0 : 8'hFF);
        write_csr(34, {24'd0, value});
        write_csr(32, 32'h4C47_0001);
        repeat (8) tick();
        write_csr(5, 17);
        write_csr(6, 9);
        write_csr(8, 0);
        write_csr(1, 32'h4C41_0001);
        frozen();
        for (int i = 0; i < 17; i++) begin
          read_sample(i, sample_value);
          if (sample_value !== (16'(value) << (8*group)))
            $fatal(1, "static loop: group=%0d pattern=%0d sample=%0d", group, pattern, i);
        end
      end
    end
    // 1 MHz counter changes, capture at nominal 1 MS/s (same clock, phase offset + wire).
    upper_group = 0;
    write_csr(33, 100);
    write_csr(32, 32'h4C47_0003);
    write_csr(5, 512);
    write_csr(6, 256);
    write_csr(7, Serdes ? 399 : 99);
    write_csr(8, 0);
    write_csr(1, 32'h4C41_0001);
    frozen();
    read_sample(0, sample_value);
    expected = sample_value[7:0];
    for (int i = 0; i < 512; i++) begin
      read_sample(i, sample_value);
      if (sample_value !== {8'd0, expected}) $fatal(1, "counter loop sample=%0d", i);
      expected++;
    end
    rst = 1;
    tick();
    if (generator_enable) $fatal(1, "reset does not disable active generator");
    $display("ok   loopback: safe enable, modes/timing/PRBS, static mapping, pad loop capture");
    $display("ALL LA LOOPBACK OK");
    $finish;
  end
  initial begin
    #20ms;
    $fatal(1, "TIMEOUT");
  end
endmodule
