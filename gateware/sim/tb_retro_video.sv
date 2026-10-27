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
  logic staged_valid=0;
  logic [28:0] staged_pixel=0;
  logic [1:0] staged_owner=0;
  int checked_writes=0;
  // Check the actual framebuffer inputs against the preceding accepted pixel.
  // Owner changes and stop must discard a queued previous-owner write.
  always @(posedge bus_clk) begin
    if(dut.framebuffer.we) begin
      assert(staged_valid && running && !rst && selected==staged_owner &&
             {dut.framebuffer.wx,dut.framebuffer.wy,dut.framebuffer.wdata}==staged_pixel)
        else $fatal(1,"staged framebuffer pixel/owner mismatch");
      checked_writes++;
    end else if(staged_valid && running && !rst && selected==staged_owner)
      $fatal(1,"staged framebuffer write dropped");
    staged_valid=!rst && dut.we;
    staged_owner=selected;
    if(dut.we) staged_pixel=dut.pixel;
  end
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
  task automatic check_audio_switch;
    audio_valid=1;audio_l=16'sh1234;audio_r=-16'sh2345;
    #150us;
    assert(dut.audio_pixel_valid && dut.audio_pixel_l==16'sh1234 &&
           dut.audio_pixel_r==-16'sh2345)
      else $fatal(1,"first owner's audio missing/swapped");
    @(negedge bus_clk);running=0;audio_valid=0;
    #5us;
    assert(!dut.audio_pixel_valid && dut.audio_pixel_l==0 && dut.audio_pixel_r==0 &&
           dut.transmitter.fill_count==0 && !dut.transmitter.pending_ready)
      else $fatal(1,"stopped owner retained queued audio");
    @(negedge bus_clk);selected=2;running=1;
    #100us;
    assert(!dut.audio_pixel_valid && dut.audio_pixel_l==0 && dut.audio_pixel_r==0)
      else $fatal(1,"old owner's audio leaked into unqualified new owner");
    @(negedge bus_clk);audio_valid=1;audio_l=-16'sh3456;audio_r=16'sh4567;
    #150us;
    assert(dut.audio_pixel_valid && dut.audio_pixel_l==-16'sh3456 &&
           dut.audio_pixel_r==16'sh4567)
      else $fatal(1,"new owner's audio missing/swapped");
    $display("ok stereo audio owner switch flushes CDC and HDMI queue; no stale samples");
  endtask
  task automatic check_native_reset_release;
    // Deassert between native clock edges. Each source must retain reset until
    // its own synchronizer has received four rising edges.
    #1ps;
    assert(dut.g_source[0].fifo.wrst && dut.g_source[1].fifo.wrst &&
           dut.g_source[2].fifo.wrst)
      else $fatal(1,"native video reset released directly from bus domain");
    fork
      begin
        repeat(3) @(posedge nes_clk);
        @(negedge nes_clk);
        assert(dut.g_source[0].fifo.wrst) else $fatal(1,"NES reset released early");
        @(negedge nes_clk);
        assert(!dut.g_source[0].fifo.wrst) else $fatal(1,"NES reset stuck");
      end
      begin
        repeat(3) @(posedge md_clk);
        @(negedge md_clk);
        assert(dut.g_source[1].fifo.wrst) else $fatal(1,"MD reset released early");
        @(negedge md_clk);
        assert(!dut.g_source[1].fifo.wrst) else $fatal(1,"MD reset stuck");
      end
      begin
        repeat(3) @(posedge snes_clk);
        @(negedge snes_clk);
        assert(dut.g_source[2].fifo.wrst) else $fatal(1,"SNES reset released early");
        @(negedge snes_clk);
        assert(!dut.g_source[2].fifo.wrst) else $fatal(1,"SNES reset stuck");
      end
    join
    $display("ok native video resets release after four destination edges");
  endtask
  initial begin
    repeat(8) @(negedge bus_clk);rst=0;rst_pix=0;
    check_native_reset_release();
    @(negedge bus_clk);running=1;
    repeat(10) @(negedge snes_clk);source_frame();source_frame();
    wait(red_seen!=0 && blue_seen!=0);
    check_audio_switch();
    @(negedge bus_clk);running=0;rst=1;
    #1ps;
    assert(dut.g_source[0].fifo.wrst && dut.g_source[1].fifo.wrst &&
           dut.g_source[2].fifo.wrst && dut.md_positions.rst)
      else $fatal(1,"warm video reset did not assert in all native domains");
    repeat(20) @(negedge bus_clk);
    rst=0;check_native_reset_release();
    repeat(20) @(negedge bus_clk);
    assert(!fault) else $fatal(1,"video fault");
    assert(checked_writes>=4) else $fatal(1,"framebuffer pipeline not exercised");
    $display("ok SNES BGR15 -> RGB333 framebuffer red/blue readback with real CDC/decimation");
    $finish;
  end
  initial begin #25ms;$fatal(1,"timeout");end
endmodule
