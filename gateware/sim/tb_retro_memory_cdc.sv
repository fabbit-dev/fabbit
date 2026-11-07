`timescale 1ns/1ps
module tb_retro_memory_cdc;
  logic sclk=0,dclk=0,srst=1,drst=1;
  always #5 sclk=~sclk;
  always #7 dclk=~dclk;
  logic req_valid=0,req_write=0,rsp_ready=0;
  logic [20:0] req_addr=0;
  logic [31:0] req_wdata=0;
  logic [3:0] req_mask=0;
  wire req_ready,rsp_valid,idle;
  wire [31:0] rsp_rdata;
  wire mem_valid,mem_write,mem_rsp_ready;
  wire [20:0] mem_addr;
  wire [31:0] mem_wdata;
  wire [3:0] mem_mask;
  logic mem_ready=0,mem_rsp_valid=0;
  logic [31:0] mem_rdata=0;
  retro_memory_cdc dut (.*);
  int issues=0,replies=0;
  always @(posedge dclk) if (mem_valid && mem_ready) issues++;
  always @(posedge sclk) if (rsp_valid && rsp_ready) replies++;
  initial begin
    repeat(5) @(negedge sclk);srst=0;drst=0;
    for(int i=0;i<20;i++) begin
      while(!req_ready) @(negedge sclk);
      req_valid=1;req_write=i[0];req_addr=21'(i);req_wdata=32'(i*3);req_mask=4'(i);
      @(negedge sclk);req_valid=0;
      while(!mem_valid) @(negedge dclk);
      repeat(4) @(negedge dclk);
      assert(mem_addr==21'(i) && mem_wdata==32'(i*3)) else $fatal(1,"snapshot");
      mem_ready=1;@(negedge dclk);mem_ready=0;
      repeat(6) @(negedge dclk);mem_rdata=32'(i+77);
      while(!mem_rsp_ready) @(negedge dclk);
      mem_rsp_valid=1;
      @(negedge dclk);mem_rsp_valid=0;
      while(!rsp_valid) @(negedge sclk);
      repeat(5) @(negedge sclk);
      assert(rsp_rdata==32'(i+77)) else $fatal(1,"response");
      rsp_ready=1;repeat(8) @(negedge sclk);rsp_ready=0;
      while(!idle) @(negedge sclk);
      assert(issues==i+1 && replies==i+1) else $fatal(1,"exactly once %d/%d",issues,replies);
    end
    $display("ok memory CDC exactly-once request/response stalls");$finish;
  end
  initial begin #100us;$fatal(1,"timeout");end
endmodule
