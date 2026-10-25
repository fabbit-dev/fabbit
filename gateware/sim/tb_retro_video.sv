`timescale 1ns/1ps
module tb_retro_video;
  logic bus_clk=0,nes_clk=0,md_clk=0,snes_clk=0,clk_pix=0,clk_5x=0;
  always #5 bus_clk=~bus_clk;
  always #23 nes_clk=~nes_clk;
  always #9 md_clk=~md_clk;
  always #6 snes_clk=~snes_clk;
  always #20 clk_pix=~clk_pix;
  always #4 clk_5x=~clk_5x;
  logic rst=1,rst_pix=1,running=0,audio_valid=0;
  logic signed[15:0] audio_l=0,audio_r=0;
  logic[1:0] selected=3;
  logic nes_we=0;logic[7:0] nes_x=0,nes_y=0;logic[8:0] nes_index=0;
  logic md_pixel=0,md_hs=1,md_vs=1,md_hde=0,md_vde=0,md_interlace=0;
  logic[3:0] md_r=0,md_g=0,md_b=0;logic[1:0] md_resolution=0;
  logic snes_pixel=0,snes_hde=0,snes_vde=0,snes_interlace=0,snes_v224=1;
  logic[8:0] snes_x=0,snes_y=0;logic[14:0] snes_rgb=0;
  wire[3:0] hdmi_p,hdmi_n;wire fault;
  retro_video dut (.*);
  int red_seen=0,blue_seen=0;
  // Observe real framebuffer read pipeline, not source activity or forced RAM.
  always @(negedge clk_pix) if(dut.visible && dut.display.de && dut.display.y==16) begin
    if(dut.display.x==64) begin
      assert(dut.display.r==255 && dut.display.g==0 && dut.display.b==0)
          else $fatal(1,"SNES red swapped R=%h G=%h B=%h",
                      dut.display.r,dut.display.g,dut.display.b);
      red_seen++;
    end
    if(dut.display.x==66) begin
      assert(dut.display.r==0 && dut.display.g==0 && dut.display.b==255)
          else $fatal(1,"SNES blue swapped");
      blue_seen++;
    end
  end
  task automatic source_frame;
    for(int x=0;x<4;x++) begin
      @(negedge snes_clk);snes_x=9'(x);snes_y=0;snes_hde=1;snes_vde=1;snes_pixel=1;
      snes_rgb=x<2 ? 15'h001f : 15'h7c00;
      @(negedge snes_clk);snes_pixel=0;
    end
    snes_hde=0;snes_vde=0;repeat(50) @(negedge snes_clk);
  endtask
  initial begin
    repeat(8) @(negedge bus_clk);rst=0;rst_pix=0;running=1;
    repeat(10) @(negedge snes_clk);source_frame();source_frame();
    wait(red_seen!=0 && blue_seen!=0);
    assert(!fault) else $fatal(1,"video fault");
    $display("ok SNES BGR15 -> RGB333 framebuffer red/blue readback with real CDC/decimation");
    $finish;
  end
  initial begin #25ms;$fatal(1,"timeout");end
endmodule
