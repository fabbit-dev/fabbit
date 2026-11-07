`default_nettype none
`timescale 1ns / 1ps
module tb_retro_pixels;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst = 1'b1, active = 1'b0, pixel_ce = 1'b0;
  logic hs_n = 1'b1, vs_n = 1'b1, hde = 1'b0, vde = 1'b0, unsupported = 1'b0;
  logic [14:0] rgb = '0;
  wire we, frame, overflow;
  wire [8:0] x;
  wire [7:0] y;
  wire [14:0] data;
  retro_pixels dut (.*);
  int pixels = 0;
  task automatic start_frame;
    hde = 1'b0;
    vde = 1'b0;
    vs_n = 1'b0;
    @(negedge clk);
    assert (frame && !we) else $fatal(1, "frame pulse");
    vs_n = 1'b1;
    repeat (3) @(negedge clk);
  endtask
  task automatic line(input int width, input int row);
    hs_n = 1'b0;
    hde = 1'b0;
    repeat (3) @(negedge clk);
    hs_n = 1'b1;
    repeat (2) @(negedge clk);
    hde = 1'b1;
    vde = 1'b1;
    for (int col = 0; col < width; col++) begin
      rgb = 15'(col ^ row);
      pixel_ce = 1'b1;
      @(negedge clk);
      assert (we && x == 9'(col) && y == 8'(row) && data == rgb)
          else $fatal(1, "native pixel position col=%d row=%d x=%d y=%d", col, row, x, y);
      pixels++;
      pixel_ce = 1'b0;
      @(negedge clk);
      assert (!we) else $fatal(1, "duplicate pixel");
    end
    hde = 1'b0;
    repeat (4) @(negedge clk);
  endtask
  initial begin
    repeat (3) @(negedge clk);
    rst = 1'b0;
    active = 1'b1;
    foreach_width: for (int mode = 0; mode < 3; mode++) begin
      int width;
      width = mode == 0 ? 256 : mode == 1 ? 320 : 512;
      start_frame();
      for (int row = 0; row < 3; row++) line(width, row);
      assert (!overflow) else $fatal(1, "valid dimensions overflow");
    end
    unsupported = 1'b1;
    pixel_ce = 1'b1;
    hde = 1'b1;
    repeat (5) @(negedge clk);
    assert (!we) else $fatal(1, "unsupported video leaked");
    active = 1'b0;
    repeat (3) @(negedge clk);
    assert (!we) else $fatal(1, "inactive video leaked");
    active = 1'b1;
    unsupported = 1'b0;
    pixel_ce = 1'b0;
    start_frame();
    line(512, 0);
    pixel_ce = 1'b1;
    hde = 1'b1;
    repeat (1100) @(negedge clk);
    assert (overflow && !we) else $fatal(1, "oversized line wrapped into framebuffer");
    $display("ok retro pixels: 256/320/512 samples, CE, line/frame sync, inactive/mode gating");
    $finish;
  end
  initial begin
    #1ms;
    $fatal(1, "timeout");
  end
endmodule
