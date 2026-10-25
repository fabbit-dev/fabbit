`default_nettype none
`timescale 1ns / 1ps

module tb_retro_control;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst = 1'b1;
  logic begin_load = 1'b0, abort_load = 1'b0, commit_load = 1'b0;
  logic [1:0] system = '0;
  logic [23:0] length = '0;
  logic all_idle = 1'b0, fifo_empty = 1'b0, init_ready = 1'b0;
  logic in_valid = 1'b0, out_ready = 1'b0;
  logic [7:0] in_data = '0;
  logic backend_done = 1'b0, backend_fail = 1'b0;
  wire in_ready, out_valid, flush_fifo, ready, loading, done, failed;
  wire [7:0] out_data;
  wire [2:0] run;
  wire [1:0] selected;
  wire [23:0] received;
  retro_control #(.MaxBytes(24'd16)) dut (.*);
  int transfers = 0;
  always @(posedge clk) begin
    if (out_valid && out_ready) transfers <= transfers + 1;
    assert ($onehot0(run)) else $fatal(1, "multiple active cores");
    assert ((out_valid && out_ready) == (in_valid && in_ready))
        else $fatal(1, "stream ownership");
  end

  task automatic start(input logic [1:0] s, input logic [23:0] n);
    @(negedge clk);
    system = s;
    length = n;
    begin_load = 1'b1;
    #1;
    assert (run == 0 && !out_valid && !in_ready) else $fatal(1, "BEGIN did not revoke owner");
    @(negedge clk);
    begin_load = 1'b0;
  endtask
  task automatic prepare;
    all_idle = 1'b0;
    fifo_empty = 1'b0;
    init_ready = 1'b0;
    repeat (4) @(negedge clk);
    assert (!ready && !flush_fifo && !out_valid && loading) else $fatal(1, "drain gate");
    all_idle = 1'b1;
    @(negedge clk);
    assert (flush_fifo && !ready && !out_valid) else $fatal(1, "missing flush");
    fifo_empty = 1'b1;
    repeat (4) @(negedge clk);
    assert (!ready && flush_fifo) else $fatal(1, "init gate");
    init_ready = 1'b1;
    @(negedge clk);
    assert (ready && !flush_fifo) else $fatal(1, "not ready");
  endtask
  task automatic send_bytes(input int n);
    for (int i = 0; i < n; i++) begin
      in_valid = 1'b1;
      in_data = 8'(i);
      out_ready = 1'b0;
      repeat (3) @(negedge clk);
      assert (!in_ready && received == 24'(i) && out_valid && out_data == 8'(i))
          else $fatal(1, "backpressure");
      out_ready = 1'b1;
      @(negedge clk);
      out_ready = 1'b0;
    end
    assert (received == 24'(n) && !in_ready && !out_valid && run == 0 && loading)
        else $fatal(1, "length boundary");
    in_valid = 1'b0;
  endtask
  initial begin
    repeat (4) @(negedge clk);
    rst = 1'b0;
    // NES -> MD -> SNES -> NES, no bitstream/BOOT/reset primitive involved.
    for (int i = 0; i < 4; i++) begin
      start(2'((i % 3) + 1), 24'd7);
      prepare();
      // Configuration cannot tear while receiving.
      system = 2'd0;
      length = 24'd1;
      send_bytes(7);
      assert (selected == 2'((i % 3) + 1)) else $fatal(1, "torn selector");
      backend_done = 1'b1;
      commit_load = 1'b1;
      @(negedge clk);
      commit_load = 1'b0;
      backend_done = 1'b0;
      assert (done && run == (3'b001 << (i % 3))) else $fatal(1, "wrong core release");
    end
    start(2'd0, 24'd1);
    assert (failed && run == 0) else $fatal(1, "invalid system");
    start(2'd2, 24'd0);
    assert (failed) else $fatal(1, "zero length");
    start(2'd2, 24'd17);
    assert (failed) else $fatal(1, "oversize");
    start(2'd2, 24'd1);
    prepare();
    in_valid = 1'b1;
    out_ready = 1'b1;
    commit_load = 1'b1;
    #1;
    assert (!out_valid && !in_ready) else $fatal(1, "early commit stream leak");
    @(negedge clk);
    commit_load = 1'b0;
    in_valid = 1'b0;
    out_ready = 1'b0;
    assert (failed && run == 0) else $fatal(1, "early commit");
    start(2'd3, 24'd1);
    prepare();
    send_bytes(1);
    commit_load = 1'b1;
    @(negedge clk);
    commit_load = 1'b0;
    assert (failed && run == 0) else $fatal(1, "backend not done");
    start(2'd3, 24'd1);
    prepare();
    backend_fail = 1'b1;
    @(negedge clk);
    assert (failed && run == 0 && !in_ready) else $fatal(1, "backend error");
    backend_fail = 1'b0;
    start(2'd1, 24'd1);
    prepare();
    in_valid = 1'b1;
    out_ready = 1'b1;
    abort_load = 1'b1;
    #1;
    assert (!out_valid && !in_ready && run == 0) else $fatal(1, "abort ownership");
    @(negedge clk);
    abort_load = 1'b0;
    in_valid = 1'b0;
    assert (!loading && !done && !failed && run == 0) else $fatal(1, "abort state");
    rst = 1'b1;
    @(negedge clk);
    assert (run == 0 && !out_valid) else $fatal(1, "reset outputs");
    assert (transfers == 29) else $fatal(1, "accepted extra stream bytes");
    $display("ok retro control: NES/MD/SNES selection, drain/flush/init, length, commit, abort");
    $finish;
  end
  initial begin
    #100us;
    $fatal(1, "timeout");
  end
endmodule
