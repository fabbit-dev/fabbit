`timescale 1ns/1ps
module tb_retro_session;
  import retro_regs_pkg::*;
  logic clk=0,rst=1,command_valid=0;
  always #5 clk=~clk;
  logic [159:0] command=0;
  wire command_complete;
  logic transport_fault=0;
  wire [1:0] selected,owner_request;
  logic [1:0] owner=0;
  logic owner_busy=0;
  wire controllers_reset,running,loading,ready,payload_done,switching;
  wire nes_freeze,nes_run,md_run,snes_run;
  logic md_stopped=1,snes_stopped=1,writer_idle=1,md_memory_idle=1;
  logic nes_done=0,nes_fail=0,nes_memory_ready=1,md_memory_ready=1,snes_memory_ready=1;
  logic [1:0] assets_ready=3;
  wire [23:0] length,rom_size,received;
  wire [17:0] save_size;
  wire [4:0] map_config;
  wire flush,nes_load,writer_start,writer_abort;
  logic stream_valid=0,backend_ready=1,backend_done=0,backend_fail=0;
  wire stream_ready;
  wire [7:0] error;
  wire [95:0] status;
  wire asset_command;
  logic asset_complete=0,asset_failed=0;
  retro_session dut (.*);
  always @(posedge clk) if(controllers_reset) owner<=owner_request;
  // Model an active ROM collector: only an explicit abort releases its idle.
  always @(negedge clk) if(writer_abort) writer_idle=1;
  task automatic cmd(input logic[31:0] v,input logic[1:0] sys);
    @(negedge clk);
    command={21'b0,18'b0,(sys==3 ? 24'd32768 : 24'd4),5'b0,
             (sys==3 ? 24'd32768 : 24'd4),sys,26'b0,v,8'(RegControl)};
    command_valid=1;
    do @(negedge clk);while(!command_complete);
    // Keep valid asserted longer than the receiver response path.
    repeat(5) @(negedge clk);
    command_valid=0;repeat(5) @(negedge clk);
  endtask
  initial begin
    repeat(4) @(negedge clk);rst=0;
    for(int sys=1;sys<=3;sys++) begin
      cmd(32'h52540001,2'(sys));
      writer_idle=0;
      cmd(32'h52540002,2'(sys));
      assert(!running && !switching && error==ErrCommit && writer_idle)
        else $fatal(1,"early COMMIT must abort collector before waiting idle");
      cmd(32'h52540004,2'(sys));
      cmd(32'h52540001,2'(sys));
      assert(ready && selected==2'(sys) && !running) else $fatal(1,"BEGIN");
      stream_valid=1;repeat(sys==3 ? 32768 : 4) @(negedge clk);stream_valid=0;
      backend_done=1;repeat(140) @(negedge clk);
      assert(payload_done && received==(sys==3 ? 32768 : 4) && !ready && !running)
          else $fatal(1,"payload");
      cmd(32'h52540002,2'(sys));
      assert(running) else $fatal(1,"commit repeated/dropped");
      cmd(32'h52540100,2'(sys));
      assert(running && !asset_command && error==ErrAssets) else $fatal(1,"unsafe asset");
      backend_done=0;
      cmd(32'h52540004,2'(sys));
      assert(!running && !switching && error==0 && controllers_reset) else $fatal(1,"abort");
      cmd(32'h52540008,2'(sys));
      assert(!running && !switching && error==ErrCommand && controllers_reset)
          else $fatal(1,"RESET after ABORT must reject without stuck command");
      cmd(32'h52540004,2'(sys));
    end
    $display("ok session BEGIN exact payload COMMIT unsafe-assets ABORT NES/MD/SNES");$finish;
  end
  initial begin #5ms;$fatal(1,"timeout");end
endmodule
