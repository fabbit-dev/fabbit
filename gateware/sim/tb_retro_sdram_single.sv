`timescale 1ns/1ps
// Single-console SDRAM owner: blanking, own-system acceptance, foreign requests.
module tb_retro_sdram_single;
  logic clk=0,rst=1,safe=1;
  always #9.312 clk=~clk;
  logic [1:0] requested=0;
  wire [1:0] owner;
  wire busy;
  logic [10:0] a=11'h234;
  logic [1:0] ba=2'd1;
  logic [2:0] command=3'b101;
  logic [31:0] data=32'h23456789;
  logic drive=1;
  wire [10:0] sd_a;
  wire [1:0] sd_ba;
  wire sd_ras_n,sd_cas_n,sd_we_n,dq_oe;
  wire [31:0] dq_out;
  retro_sdram_single #(.System(2'd2)) dut (.*);
  always @(negedge clk) begin
    if (rst || safe || busy || owner!=2)
      assert ({sd_ras_n,sd_cas_n,sd_we_n}==3'b111 && !dq_oe && sd_a==0 && sd_ba==0 &&
              dq_out==0) else $fatal(1,"single owner did not blank command/DQ");
    else
      assert (sd_a==a && sd_ba==ba && {sd_ras_n,sd_cas_n,sd_we_n}==command && dq_oe &&
              dq_out==data) else $fatal(1,"single owner payload mismatch");
    assert (owner==0 || owner==2) else $fatal(1,"foreign owner %0d", owner);
  end
  task automatic settle_to(input logic [1:0] want);
    requested=want;safe=1;
    repeat(80) @(negedge clk);
  endtask
  initial begin
    repeat(4) @(negedge clk);rst=0;
    settle_to(2);
    assert (owner==2 && !busy) else $fatal(1,"MD owner not reached");
    safe=0;repeat(4) @(negedge clk);
    assert (!sd_ras_n || !sd_cas_n || !sd_we_n) else $fatal(1,"payload not forwarded");
    // Not safe: request must wait.
    requested=0;repeat(80) @(negedge clk);
    assert (owner==2 && busy) else $fatal(1,"owner changed without safe");
    settle_to(0);
    assert (owner==0 && !busy) else $fatal(1,"idle not reached");
    // Foreign systems are never adopted and keep the bus blanked and busy.
    for (int sys=1;sys<=3;sys+=2) begin
      settle_to(2'(sys));
      assert (owner==0 && busy) else $fatal(1,"foreign system %0d adopted",sys);
    end
    settle_to(2);
    rst=1;@(negedge clk);rst=0;
    assert (owner==0 && busy) else $fatal(1,"reset did not drop owner");
    repeat(80) @(negedge clk);
    assert (owner==2) else $fatal(1,"owner not reacquired after reset");
    $display("ok single SDRAM owner: blanking, safe-only handover, foreign systems rejected");
    $finish;
  end
  initial begin #100us;$fatal(1,"timeout");end
endmodule
