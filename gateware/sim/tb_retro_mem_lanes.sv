`default_nettype none
`timescale 1ns / 1ps

module tb_retro_mem_lanes;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst = 1'b1;
  logic req_valid = 1'b0, req_write = 1'b0, rsp_ready = 1'b0;
  wire req_ready, rsp_valid;
  logic [5:0] req_addr = '0;
  logic [31:0] req_wdata = '0;
  logic [3:0] req_mask = '0;
  wire [31:0] rsp_rdata;
  wire mem_valid, mem_write, mem_rsp_ready;
  wire [5:0] mem_addr;
  wire [31:0] mem_wdata;
  logic mem_ready = 1'b0, mem_rsp_valid = 1'b0;
  logic [31:0] mem_rdata = '0;
  retro_mem_lanes #(.AddrBits(6)) dut (.*);

  logic [31:0] memory [64];
  logic [31:0] expected [64];
  int reads = 0, writes = 0, cycles = 0;
  int delay_left = 0;
  logic pending = 1'b0;
  logic [31:0] pending_data = '0;
  logic [31:0] random_state = 32'h81A5C347;
  function automatic logic [31:0] step(input logic [31:0] x);
    logic [31:0] y;
    y = x ^ (x << 13);
    y ^= y >> 17;
    return y ^ (y << 5);
  endfunction

  // Full-word backend with request stalls and variable response delay. DQM absent.
  always @(posedge clk) begin
    cycles <= cycles + 1;
    random_state <= step(random_state);
    if (rst) begin
      pending <= 1'b0;
      mem_rsp_valid <= 1'b0;
      mem_ready <= 1'b0;
    end else begin
      mem_ready <= !pending && !mem_rsp_valid && random_state[0];
      if (mem_valid && mem_ready) begin
        assert (!pending && !mem_rsp_valid) else $fatal(1, "overlapping physical request");
        pending <= 1'b1;
        mem_ready <= 1'b0;
        delay_left <= int'(random_state[4:1]) + 1;
        pending_data <= memory[mem_addr];
        if (mem_write) begin
          memory[mem_addr] <= mem_wdata;
          writes <= writes + 1;
        end else reads <= reads + 1;
      end
      if (pending) begin
        if (delay_left == 0) begin
          mem_rdata <= pending_data;
          mem_rsp_valid <= 1'b1;
          pending <= 1'b0;
        end else delay_left <= delay_left - 1;
      end
      if (mem_rsp_valid && mem_rsp_ready) mem_rsp_valid <= 1'b0;
    end
  end

  task automatic transaction(input bit wr, input logic [5:0] a,
                              input logic [31:0] d, input logic [3:0] m);
    logic [31:0] before_data;
    int before_reads, before_writes;
    before_data = expected[a];
    before_reads = reads;
    before_writes = writes;
    @(negedge clk);
    req_valid = 1'b1;
    req_write = wr;
    req_addr = a;
    req_wdata = d;
    req_mask = m;
    do @(posedge clk); while (!req_ready);
    @(negedge clk);
    req_valid = 1'b0;
    // Inputs no longer belong to the transaction; snapshot must isolate RMW.
    req_addr = ~a;
    req_wdata = ~d;
    req_mask = ~m;
    req_write = !wr;
    while (!rsp_valid) @(negedge clk);
    repeat (4) begin
      assert (rsp_valid && !req_ready && !mem_valid) else $fatal(1, "unstable stalled response");
      @(negedge clk);
    end
    if (!wr) assert (rsp_rdata === before_data) else $fatal(1, "read mismatch");
    else for (int i = 0; i < 4; i++) if (m[i]) expected[a][i*8+:8] = d[i*8+:8];
    assert (memory[a] === expected[a]) else $fatal(1, "lane corruption mask=%h addr=%d", m, a);
    assert (reads - before_reads == ((!wr || (m != 0 && m != 15)) ? 1 : 0))
        else $fatal(1, "wrong physical read count");
    assert (writes - before_writes == ((wr && m != 0) ? 1 : 0))
        else $fatal(1, "wrong physical write count");
    rsp_ready = 1'b1;
    @(negedge clk);
    rsp_ready = 1'b0;
  endtask

  initial begin
    for (int i = 0; i < 64; i++) begin
      memory[i] = 32'h12345678 ^ (32'(i) * 32'h1020304);
      expected[i] = memory[i];
    end
    repeat (4) @(negedge clk);
    rst = 1'b0;
    for (int mask = 0; mask < 16; mask++) begin
      transaction(1'b1, 6'(mask), 32'hE1C3A587 ^ 32'(mask), 4'(mask));
      transaction(1'b0, 6'(mask), '0, '0);
    end
    for (int i = 0; i < 256; i++) begin
      transaction(1'b1, random_state[5:0], random_state, random_state[11:8]);
      transaction(1'b0, random_state[5:0], '0, '0);
    end
    // A reset at a quiescent boundary drops all handshake outputs.
    @(negedge clk);
    rst = 1'b1;
    @(negedge clk);
    assert (!rsp_valid && !mem_valid && !req_ready) else $fatal(1, "reset handshake");
    $display("ok retro memory: 16 masks, RMW, snapshots, backpressure, %0d cycles", cycles);
    $finish;
  end
  initial begin
    #1ms;
    $fatal(1, "timeout");
  end
endmodule
