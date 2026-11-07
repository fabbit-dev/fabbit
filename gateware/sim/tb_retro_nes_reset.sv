`timescale 1ns/1ps
module tb_retro_nes_reset;
  logic clk=0,resetn=0,clkref=0;
  always #8 clk=~clk;
  int phase=0,refreshes=0,activates=0;
  always @(negedge clk) begin
    phase=(phase+1)%6;
    clkref=phase<3;
  end
  wire [31:0] data;
  wire drive,busy,cs,ras,cas,we,cke;
  wire [10:0] address;
  wire [3:0] masks;
  wire [1:0] bank;
  retro_nes_sdram_core #(.FREQ(1000000)) dut (
      .clk,.resetn,.clkref,.busy,.dq_input(32'b0),.dq_output(data),.dq_drive(drive),
      .SDRAM_A(address),.SDRAM_DQM(masks),.SDRAM_BA(bank),.SDRAM_nCS(cs),
      .SDRAM_nRAS(ras),.SDRAM_nCAS(cas),.SDRAM_nWE(we),.SDRAM_CKE(cke),
      .addrA(22'b0),.weA(1'b0),.dinA(8'b0),.oeA(1'b1),.doutA(),
      .addrB(22'b0),.weB(1'b0),.dinB(8'b0),.oeB(1'b0),.doutB(),
      .rv_addr(20'b0),.rv_din(16'b0),.rv_ds(2'b0),.rv_dout(),
      .rv_req(1'b0),.rv_req_ack(),.rv_we(1'b0));
  always @(negedge clk)
    if(resetn && !busy && {cs,ras,cas,we}===4'b0001) refreshes++;
  always @(negedge clk)
    if(resetn && !busy && {cs,ras,cas,we}===4'b0011) activates++;
  initial begin
    repeat(4) @(negedge clk);
    if({cs,ras,cas,we}!==4'b1111 || drive!==0)
      $fatal(1,"reset must drive NOP and release DQ");
    resetn=1;
    wait(!busy);
    repeat(1600) @(negedge clk);
    if(activates!=1) $fatal(1,"held cold-start read must issue exactly once: %0d",activates);
    if(refreshes<2) $fatal(1,"periodic refresh absent after four-state cold reset: %0d",refreshes);
    wait({cs,ras,cas,we}===4'b0001);
    @(negedge clk);resetn=0;
    repeat(4) @(negedge clk);
    if({cs,ras,cas,we}!==4'b1111 || drive!==0)
      $fatal(1,"warm reset repeated old command");
    resetn=1;
    wait(!busy);
    repeat(100) @(negedge clk);
    if(activates!=2)
      $fatal(1,"held read must restart exactly once after warm reset: %0d",activates);
    $display("ok NES four-state cold refresh and warm reset NOP/DQ release");
    $finish;
  end
  initial begin #100us;$fatal(1,"timeout");end
endmodule
