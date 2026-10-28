`timescale 1ns/1ps
// diag/retro_sdram_eye через QSPI: ID, проходы без ошибок на модели SDRAM, сдвиг фазы.
// Модель с идеальными ножками; окно на плате меряет сам стенд, не этот тест.
module tb_retro_sdram_eye;
  parameter bit Mode = 1'b0;
  logic clk=0; always #20 clk=~clk;
  wire led,uart_tx,esp_irq;
  logic esp_sck=0,esp_cs_n=1;
  wire [3:0] esp_d;
  logic [3:0] host_data=0;
  logic host_drive=0;
  assign esp_d=host_drive ? host_data : {4{1'bz}};
  wire sdram_clk,sdram_ras_n,sdram_cas_n,sdram_we_n;
  wire [10:0] sdram_a;
  wire [1:0] sdram_ba;
  wire [31:0] sdram_dq;
  retro_sdram_eye #(.Mode(Mode)) dut (.*);
  sdram_model #(.DynamicCasTiming(1'b1),.TOh(2ns),.TRcd(21ns)) model (
      .clk(sdram_clk),.cke(1'b1),.cs_n(1'b0),.ras_n(sdram_ras_n),.cas_n(sdram_cas_n),
      .we_n(sdram_we_n),.ba(sdram_ba),.a(sdram_a),.dqm(4'b0),.dq(sdram_dq));
  localparam time T=100ns;
  task automatic nib(input logic[3:0] n); host_data=n;#(T/2) esp_sck=1;#(T/2) esp_sck=0; endtask
  task automatic header(input logic[7:0] op,input logic[23:0] addr);
    esp_cs_n=0;host_drive=1;#(T/2);nib(op[7:4]);nib(op[3:0]);
    for(int i=5;i>=0;i--) nib(addr[i*4+:4]);
  endtask
  task automatic finish_qspi; host_drive=0;#(T/2) esp_cs_n=1;#(T*2); endtask
  task automatic write_csr(input logic[7:0] addr,input logic[31:0] value);
    header(8'h30,{16'b0,addr});for(int i=7;i>=0;i--) nib(value[i*4+:4]);finish_qspi();
  endtask
  task automatic read_csr(input logic[7:0] addr,output logic[31:0] value);
    header(8'h31,{16'b0,addr});host_drive=0;
    repeat(8) begin #(T/2) esp_sck=1;#(T/2) esp_sck=0;end
    for(int i=7;i>=0;i--) begin #(T/2) esp_sck=1;value[i*4+:4]=esp_d;#(T/2) esp_sck=0; end
    finish_qspi();
  endtask
  initial begin
    logic [31:0] v;
    #400us;
    read_csr(0,v); assert(v=="SDRE") else $fatal(1,"ID %h",v);
    read_csr(7,v); assert(v==(Mode ? 560 : 1232)) else $fatal(1,"period %0d",v);
    write_csr(8,8);              // 256 слов на проход
    write_csr(1,1);
    do read_csr(2,v); while(v[31:16]<3);
    write_csr(1,0);
    do read_csr(2,v); while(!v[1]);
    read_csr(3,v); assert(v==0) else $fatal(1,"errors %0d",v);
    assert(model.errors==0) else $fatal(1,"model errors %0d",model.errors);
    // The ideal MMCM model has no fine phase shift: PSDONE is checked on hardware.
    $display("ok retro_sdram_eye mode %0d: ID, period, 3 passes 0 errors", Mode);
    $finish;
  end
  initial begin #20ms; $fatal(1,"timeout"); end
endmodule
