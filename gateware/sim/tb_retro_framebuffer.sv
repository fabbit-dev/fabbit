`default_nettype none
`timescale 1ns / 1ps
module tb_retro_framebuffer #(
    parameter int ChannelBits = 3
);
  import video_pkg::*;
  logic wclk = 1'b0, clk = 1'b0;
  always #7 wclk = ~wclk;
  always #10 clk = ~clk;
  logic we = 1'b0, clear = 1'b1, visible = 1'b0, wide = 1'b1, tall = 1'b1;
  logic [8:0] wx = '0;
  logic [7:0] wy = '0;
  logic [11:0] wdata = '0;
  vpx_t px_in, px_out;
  retro_framebuffer #(.ChannelBits(ChannelBits)) dut (.*);
  function automatic logic [11:0] pixel(input int x, input int y);
    return {4'(x), 4'(y), 4'(x ^ y)};
  endfunction
  task automatic point(input int x, input int y, input bit expect_visible,
                        input int sx, input int sy);
    @(negedge clk);
    px_in = '{x:12'(x), y:12'(y), de:1'b1, hs:1'b1, vs:1'b1, sof:1'b0,
              r:8'hFF, g:8'hFF, b:8'hFF};
    repeat (2) @(negedge clk);
    assert (px_out.x == 12'(x) && px_out.y == 12'(y) && px_out.de)
        else $fatal(1, "timing pipeline");
    if (expect_visible) begin
      logic [11:0] p;
      logic [23:0] expected;
      p = pixel(sx, sy);
      expected = ChannelBits == 3 ?
          {p[11:9], p[11:9], p[11:10], p[7:5], p[7:5], p[7:6], p[3:1], p[3:1], p[3:2]} :
          {p[11:8], p[11:8], p[7:4], p[7:4], p[3:0], p[3:0]};
      assert ({px_out.r, px_out.g, px_out.b} == expected)
          else $fatal(1, "framebuffer pixel x=%d y=%d", x, y);
    end else assert ({px_out.r, px_out.g, px_out.b} == 0) else $fatal(1, "letterbox leak");
  endtask
  initial begin
    px_in = '0;
    for (int y = 0; y < 240; y++) begin
      for (int x = 0; x < 320; x++) begin
        @(negedge wclk);
        wx = 9'(x);
        wy = 8'(y);
        wdata = pixel(x, y);
        we = 1'b1;
      end
    end
    @(negedge wclk);
    we = 1'b0;
    clear = 1'b0;
    visible = 1'b1;
    point(0, 0, 1'b1, 0, 0);
    point(639, 479, 1'b1, 319, 239);
    point(237, 131, 1'b1, 118, 65);
    // Every native BRAM bank boundary and its preceding word, including final bank.
    for (int bank = 1; bank < 19; bank++) begin
      for (int offset = 0; offset < 2; offset++) begin
        int address;
        address = bank*4096 - offset;
        point((address % 320)*2, (address / 320)*2, 1'b1, address % 320, address / 320);
      end
    end
    wide = 1'b0;
    tall = 1'b0;
    point(63, 16, 1'b0, 0, 0);
    point(64, 16, 1'b1, 0, 0);
    point(575, 463, 1'b1, 255, 223);
    point(576, 463, 1'b0, 0, 0);
    point(64, 15, 1'b0, 0, 0);
    point(64, 464, 1'b0, 0, 0);
    clear = 1'b1;
    point(64, 16, 1'b0, 0, 0);
    clear = 1'b0;
    visible = 1'b0;
    point(64, 16, 1'b0, 0, 0);
    $display("ok retro framebuffer: 320x240 RGB%0d, async write, bars, blanking", ChannelBits*111);
    $finish;
  end
  initial begin
    #2ms;
    $fatal(1, "timeout");
  end
endmodule
