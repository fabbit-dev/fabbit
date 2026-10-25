// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
`default_nettype none
module tb_retro_audio_cdc;
  logic clk_pix = 0;
  always #19.851116 clk_pix = ~clk_pix;
  wire [3:0] finished;
  tb_retro_audio_cdc_case #(.ClockHz(21477272), .HalfPeriod(23.280426)) nes (
      .clk_pix, .finished(finished[0]));
  tb_retro_audio_cdc_case #(.ClockHz(53693175), .HalfPeriod(9.312173)) md (
      .clk_pix, .finished(finished[1]));
  tb_retro_audio_cdc_case #(.ClockHz(85909088), .HalfPeriod(5.820106)) snes (
      .clk_pix, .finished(finished[2]));
  tb_retro_audio_cdc_case #(.ClockHz(100000000), .HalfPeriod(5.0)) service (
      .clk_pix, .finished(finished[3]));
  initial begin
    wait (&finished);
    $display("PASS audio CDC all source clocks: rate, coherent bundle, held samples, mute/reset");
    $finish;
  end
  initial begin #40000000; $fatal(1,"CDC timeout"); end
endmodule

module tb_retro_audio_cdc_case #(
    parameter int unsigned ClockHz = 100000000,
    parameter realtime HalfPeriod = 5.0
) (
    input wire clk_pix,
    output logic finished = 0
);
  logic clk_src = 0, rst_src = 1, rst_pix = 1, sample_valid = 0;
  bit source_changes = 1;
  always #(HalfPeriod) clk_src = ~clk_src;
  logic signed [15:0] sample_l = 0, sample_r = -1;
  wire audio_valid;
  wire signed [15:0] audio_l, audio_r;
  retro_audio_cdc #(.ClockHz(ClockHz)) dut (.*);
  int captures = 0, updates = 0, source_cycles = 0, last_capture = 0;
  always @(negedge clk_src) begin
    if (!rst_src) begin
      source_cycles++;
      // Change faster than capture; right channel is a coherence checksum.
      if (source_changes) begin
        sample_l <= sample_l + 16'sd1;
        sample_r <= ~(sample_l + 16'sd1);
      end
    end
  end
  always @(posedge clk_src) begin
    if (rst_src) last_capture = 0;
    else if (dut.capture) begin
      captures++;
      if (last_capture != 0) assert (source_cycles-last_capture == ClockHz/48000 ||
                                    source_cycles-last_capture == ClockHz/48000+1);
      last_capture = source_cycles;
    end
  end
  always @(negedge clk_pix) if (!rst_pix && audio_valid) begin
    assert (audio_r == ~audio_l) else $fatal(1,"torn CDC %0d",ClockHz);
    if (dut.transferred_stb) updates++;
  end
  initial begin
    repeat (12) @(negedge clk_pix);
    rst_pix = 0;
    @(negedge clk_src); rst_src = 0; sample_valid = 1;
    repeat (600000) @(negedge clk_src);
    assert (captures == int'(longint'(source_cycles)*48000/longint'(ClockHz)));
    assert (updates >= captures-2 && captures > 200);
    @(negedge clk_src); sample_valid = 0;
    repeat (1000) @(negedge clk_pix);
    assert (!audio_valid && audio_l == 0 && audio_r == 0);
    @(negedge clk_pix); rst_pix = 1; rst_src = 1;
    repeat (12) @(negedge clk_pix);
    assert (!audio_valid && audio_l == 0 && audio_r == 0);
    @(negedge clk_src);
    source_changes = 0; sample_l = 16'h1234; sample_r = ~16'h1234;
    rst_src = 0;
    @(negedge clk_pix); rst_pix = 0;
    repeat (1000) @(negedge clk_pix);
    assert (!audio_valid && audio_l == 0 && audio_r == 0);
    @(negedge clk_src); sample_valid = 1;
    repeat (1000) @(negedge clk_pix);
    assert (audio_valid && audio_l == 16'h1234 && audio_r == ~16'h1234);
    finished = 1;
  end
endmodule
