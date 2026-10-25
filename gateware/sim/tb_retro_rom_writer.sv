`default_nettype none
`timescale 1ns / 1ps
module tb_retro_rom_writer;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst = 1'b1, start_valid = 1'b0, abort_load = 1'b0, in_valid = 1'b0;
  logic [23:0] length = '0;
  logic [20:0] base_word = '0;
  logic [7:0] in_data = '0;
  wire start_ready, in_ready, idle, done, failed;
  wire [23:0] received;
  wire mem_valid, mem_rsp_ready;
  wire [20:0] mem_addr;
  wire [31:0] mem_wdata;
  logic mem_ready = 1'b0, mem_rsp_valid = 1'b0;
  retro_rom_writer dut (.*);
  int writes = 0;
  logic [31:0] captured [64];
  logic [20:0] addresses [64];
  task automatic start(input logic [23:0] n, input logic [20:0] base);
    @(negedge clk);
    assert (start_ready) else $fatal(1, "writer not start-ready");
    start_valid = 1'b1;
    length = n;
    base_word = base;
    @(negedge clk);
    start_valid = 1'b0;
  endtask
  task automatic byte_in(input logic [7:0] b);
    while (!in_ready) @(negedge clk);
    in_valid = 1'b1;
    in_data = b;
    @(negedge clk);
    in_valid = 1'b0;
  endtask
  task automatic retire;
    while (!mem_valid) @(negedge clk);
    repeat (3) @(negedge clk);
    addresses[writes] = mem_addr;
    captured[writes] = mem_wdata;
    writes++;
    mem_ready = 1'b1;
    @(negedge clk);
    mem_ready = 1'b0;
    repeat (3) @(negedge clk);
    assert (!done && !idle && mem_rsp_ready) else $fatal(1, "premature completion");
    mem_rsp_valid = 1'b1;
    @(negedge clk);
    mem_rsp_valid = 1'b0;
  endtask
  initial begin
    repeat (3) @(negedge clk);
    rst = 1'b0;
    for (int n = 1; n <= 9; n++) begin
      int first;
      first = writes;
      start(24'(n), 21'd123);
      length = 24'd1;
      base_word = '1;  // snapshot, not live configuration
      for (int b = 0; b < n; b++) begin
        byte_in(8'(b + 18));
        if (b % 4 == 3 || b == n - 1) retire();
      end
      assert (done && idle && received == 24'(n)) else $fatal(1, "not done");
      assert (writes - first == (n + 3) / 4) else $fatal(1, "word count");
      for (int word = first; word < writes; word++) begin
        assert (addresses[word] == 21'(123 + word - first)) else $fatal(1, "address snapshot");
        for (int lane = 0; lane < 4; lane++) begin
          int b;
          b = (word - first)*4 + lane;
          assert (captured[word][lane*8+:8] == (b < n ? 8'(b + 18) : 8'hFF))
              else $fatal(1, "packing/tail");
        end
      end
    end
    start(24'd0, '0);
    assert (failed && idle) else $fatal(1, "zero accepted");
    start(24'd4194305, '0);
    assert (failed) else $fatal(1, "oversize accepted");
    start(24'd5, 21'h1FFFFF);
    assert (failed) else $fatal(1, "address wrap accepted");
    // Abort before a full word: no physical write.
    start(24'd8, '0);
    byte_in(8'h01);
    abort_load = 1'b1;
    @(negedge clk);
    abort_load = 1'b0;
    assert (idle && !done && !mem_valid) else $fatal(1, "collect abort");
    // Abort while pending request, then drain: never drop valid before ready.
    start(24'd1, '0);
    byte_in(8'h5A);
    abort_load = 1'b1;
    @(negedge clk);
    assert (mem_valid && !idle && !in_ready) else $fatal(1, "abort pending request");
    abort_load = 1'b0;
    retire();
    assert (idle && !done) else $fatal(1, "abort drain");
    start(24'd1, 21'd42);
    byte_in(8'hB7);
    retire();
    assert (done && captured[writes-1] == 32'hFFFFFFB7) else $fatal(1, "restart");
    $display("ok retro ROM writer: packed bytes/tails, length/base snapshots, abort drain/restart");
    $finish;
  end
  initial begin
    #100us;
    $fatal(1, "timeout");
  end
endmodule
