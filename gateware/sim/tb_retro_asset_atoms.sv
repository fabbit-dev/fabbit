`timescale 1ns/1ps
module tb_retro_asset_atoms;
  import retro_regs_pkg::*;
  logic clk=0,rst=1,valid=0,stopped=1;
  always #5 clk=~clk;
  logic [39:0] command=0;
  wire complete,error,start,byte_valid,byte_ready,byte_last,asset_busy,asset_done;
  wire [1:0] channel;
  wire [10:0] byte_addr;
  wire [7:0] byte_data;
  wire [2:0] asset_error;
  wire ipl_clear,ipl_we,coeff_clear,coeff_we,ipl_ready,coeff_ready;
  wire [5:0] ipl_addr;
  wire [7:0] ipl_data,ipl_read_data;
  wire [8:0] coeff_addr;
  wire [11:0] coeff_data;
  wire signed [11:0] coeff_read_data;
  retro_asset_atoms dut (.*);
  snes_asset_loader loader (.clk,.reset(rst),.run(!stopped),.start,.channel,
      .byte_valid,.byte_ready,.byte_addr,.byte_data,.byte_last,
      .backend_ipl_ready(ipl_ready),.backend_coeff_ready(coeff_ready),.busy(asset_busy),
      .done(asset_done),.error(asset_error),.ipl_clear,.ipl_we,.ipl_addr,.ipl_data,
      .coeff_clear,.coeff_we,.coeff_addr,.coeff_data);
  snes_assets backend (.clk,.reset(rst),.run(!stopped),.ipl_clear,.ipl_we,.ipl_addr,.ipl_data,
      .ipl_read_addr(6'd0),.ipl_read_data,.ipl_ready,.coeff_clear,.coeff_we,.coeff_addr,
      .coeff_data,.coeff_read_addr(9'd0),.coeff_read_data,.coeff_ready);
  task automatic atom(input logic [7:0] regaddr,input logic [31:0] value);
    @(negedge clk);command={value,regaddr};valid=1;
    while(!complete) @(negedge clk);
    valid=0;repeat(3) @(negedge clk);
  endtask
  initial begin
    repeat(3) @(negedge clk);rst=0;
    atom(RegControl,32'h52540300);
    assert(error && !ipl_ready && !coeff_ready && !asset_busy) else $fatal(1,"both clear");
    atom(RegControl,32'h52540100);
    for(int i=0;i<11;i++) atom(RegIpl,32'(i<<8)|32'(i));
    atom(RegControl,32'h52540100); // interrupted session restart, no global reset
    for(int i=0;i<64;i++) atom(RegIpl,32'(i<<8)|32'(i));
    assert(ipl_ready && !coeff_ready && !error) else $fatal(1,"IPL atoms");
    atom(RegControl,32'h52540200);
    for(int i=0;i<512;i++) atom(RegCoeff,32'(i<<12)|32'(i));
    assert(ipl_ready && coeff_ready && !error && !asset_busy) else $fatal(1,"coeff atoms");
    stopped=0;atom(RegControl,32'h52540100);
    assert(error && ipl_ready && coeff_ready) else $fatal(1,"running clear destroyed assets");
    $display("ok separate IPL/coefficient CLEAR sessions; 64/512 atoms, unsafe clear retained");
    $finish;
  end
  initial begin #1ms;$fatal(1,"timeout");end
endmodule
