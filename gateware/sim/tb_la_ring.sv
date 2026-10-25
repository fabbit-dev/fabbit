`default_nettype none
`timescale 1ns / 1ps

module la_ring_case #(
    parameter int K = 1,
    localparam int Frames = 8,
    localparam int Capacity = (Frames - ((K > 1) ? 1 : 0)) * K
) (output logic finished = 0);
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst = 1, arm = 0, abort_capture = 0, sample_valid = 0;
  logic [31:0] total = 0, post = 0;
  logic [15:0] mask = 0, value = 0, rise_mask = 0, fall_mask = 0;
  logic [16*K-1:0] samples = 0;
  wire busy, triggered, done, bad;
  wire [31:0] count, trigger_index, first;
  logic re = 0;
  logic [2:0] raddr = 0;
  wire [16*K-1:0] rdata;
  la_ring #(.SamplesPerFrame(K), .FrameDepth(Frames)) dut (
      .clk(clk), .rst(rst), .arm(arm), .abort_capture(abort_capture),
      .cfg_total(total), .cfg_post(post), .cfg_mask(mask), .cfg_value(value),
      .cfg_rise(rise_mask), .cfg_fall(fall_mask),
      .sample_valid(sample_valid), .sample_data(samples),
      .busy(busy), .triggered(triggered), .done(done), .bad_config(bad),
      .sample_count(count), .trigger_index(trigger_index), .first_sample(first),
      .read_enable(re), .read_frame(raddr), .read_data(rdata));

  task automatic tick();
    @(posedge clk);
    #1;
    @(negedge clk);
  endtask

  task automatic configure(input int n, input int p, input int trigger_at);
    sample_valid = 0;
    total = 32'(n);
    post = 32'(p);
    mask = 16'hFFFF;
    value = 16'(trigger_at);
    rise_mask = 0;
    fall_mask = 0;
    arm = 1;
    tick();
    arm = 0;
  endtask

  task automatic send_frame(input int base);
    for (int j = 0; j < K; j++) samples[16*j+:16] = 16'(base + j);
    sample_valid = 1;
    tick();
    sample_valid = 0;
  endtask

  task automatic verify_window(input int n, input int p, input int trigger_at);
    int physical, lane, expected;
    if (!done || busy || bad || !triggered || count != n || trigger_index != n-p)
      $fatal(1, "K=%0d incorrect metadata n=%0d p=%0d trigger=%0d", K, n, p, trigger_at);
    for (int i = 0; i < n; i++) begin
      physical = (int'(first) + i) % (Frames*K);
      lane = physical % K;
      raddr = 3'(physical / K);
      re = 1;
      tick();
      expected = trigger_at - (n-p) + i;
      if (rdata[16*lane+:16] !== 16'(expected))
        $fatal(1, "K=%0d sample[%0d]=%0d expected %0d first=%0d", K, i,
               rdata[16*lane+:16], expected, first);
    end
    re = 0;
  endtask

  initial begin
    repeat (3) tick();
    rst = 0;
    // Every lane, all post lengths, short and maximum windows, multiple physical wraps.
    for (int n = 1; n <= Capacity; n++) begin
      for (int p = 1; p <= n; p++) begin
        for (int lane = 0; lane < K; lane++) begin
          int target;
          target = 3*Frames*K + lane;
          configure(n, p, target);
          for (int f = 0; busy && f < 8*Frames; f++) send_frame(f*K);
          verify_window(n, p, target);
          // Extra clocks and changing inputs cannot alter the frozen window.
          send_frame(9000);
          verify_window(n, p, target);
        end
      end
    end
    // Early level matches are ignored until the requested prehistory exists.
    configure(Capacity, 1, 0);
    mask = 0;  // Shadow changes after ARM must not affect this capture.
    send_frame(0);
    if (triggered) $fatal(1, "early trigger accepted");
    abort_capture = 1;
    tick();
    abort_capture = 0;
    if (done || busy || count != 0) $fatal(1, "abort did not invalidate capture");
    // No-mask immediate trigger after prefill; edge at frame boundary with stalls.
    total = 32'(Capacity);
    post = 1;
    arm = 1;
    tick();
    arm = 0;
    for (int f = 0; busy; f++) send_frame(f*K);
    verify_window(Capacity, 1, Capacity-1);
    configure(K+1, 1, 0);
    abort_capture = 1;
    tick();
    abort_capture = 0;
    mask = 0;
    rise_mask = 1;
    total = 32'(K+1);
    arm = 1;
    tick();
    arm = 0;
    samples = 0;
    sample_valid = 1;
    tick();
    sample_valid = 0;
    samples = '1;
    repeat (3) tick();
    if (triggered) $fatal(1, "invalid sample advanced edge trigger");
    sample_valid = 1;
    tick();
    sample_valid = 0;
    if (!done || trigger_index != K) $fatal(1, "frame-boundary edge trigger failed");
    // Falling edge must work at every lane, including the previous-frame boundary.
    for (int lane = 0; lane < K; lane++) begin
      mask = 0;
      rise_mask = 0;
      fall_mask = 1;
      total = 32'(K+1);
      post = 1;
      arm = 1;
      tick();
      arm = 0;
      samples = '1;
      sample_valid = 1;
      tick();
      for (int j = 0; j < K; j++) samples[16*j+:16] = (j < lane) ? 16'hFFFF : 16'd0;
      tick();
      sample_valid = 0;
      if (!done || trigger_index != K || int'(first) != lane)
        $fatal(1, "K=%0d falling lane %0d incorrect trigger/window", K, lane);
    end
    // Several lanes match: choose the earliest eligible lane, not the last match.
    total = 1;
    post = 1;
    mask = 0;
    fall_mask = 0;
    arm = 1;
    tick();
    arm = 0;
    send_frame(400);
    verify_window(1, 1, 400);
    rise_mask = 1;
    fall_mask = 1;
    arm = 1;
    tick();
    arm = 0;
    if (!bad || busy) $fatal(1, "contradictory edge masks accepted");
    configure(0, 1, 0);
    if (!bad || busy || done) $fatal(1, "zero length accepted");
    configure(Capacity+1, 1, 0);
    if (!bad || busy) $fatal(1, "excess capacity accepted");
    configure(1, 0, 0);
    if (!bad || busy) $fatal(1, "zero post accepted");
    configure(1, 2, 0);
    if (!bad || busy) $fatal(1, "post > total accepted");
    $display("ok   ring K=%0d: lengths/post/lanes, wrap, freeze, prefill, edge, abort, config", K);
    finished = 1;
  end
endmodule

module tb_la_ring;
  wire a, b, c;
  la_ring_case #(.K(1)) u_one (.finished(a));
  la_ring_case #(.K(2)) u_two (.finished(b));
  la_ring_case #(.K(8)) u_eight (.finished(c));
  initial begin
    wait (a && b && c);
    $display("ВСЁ OK");
    $finish;
  end
  initial begin
    #100ms;
    $fatal(1, "TIMEOUT");
  end
endmodule
