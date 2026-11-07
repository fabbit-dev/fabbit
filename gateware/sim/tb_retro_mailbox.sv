`timescale 1ns/1ps
module tb_retro_mailbox;
  logic sclk=0,dclk=0,srst=1,drst=1,send=0,complete=1;
  always #5 sclk=~sclk;
  always #7 dclk=~dclk;
  logic [31:0] data=0;
  wire busy,valid;
  wire [31:0] received;
  retro_mailbox dut (.*);
  int accepted=0;
  always @(posedge dclk) if(valid && complete) accepted++;
  initial begin
    repeat(5) @(negedge sclk);srst=0;drst=0;
    repeat(8) @(negedge dclk);
    assert(!valid && accepted==0) else $fatal(1,"complete acknowledged absent request");
    for(int i=0;i<20;i++) begin
      while(busy) @(negedge sclk);
      data=32'h12340000+32'(i);send=1;
      @(negedge sclk);send=0;data=~data;
      if(i[0]) begin
        complete=0;
        wait(valid);
        repeat(8) begin
          @(negedge dclk);
          assert(valid && busy && received==32'h12340000+32'(i))
            else $fatal(1,"captured payload changed while stalled");
        end
        complete=1;
      end
      wait(!busy);
      repeat(5) @(negedge dclk);
      assert(!valid && accepted==i+1) else $fatal(1,"mailbox duplicate/lost capture");
      @(negedge sclk);
    end
    srst=1;drst=1;repeat(5) @(negedge sclk);srst=0;drst=0;
    repeat(8) @(negedge dclk);
    assert(!valid && !busy && received==0) else $fatal(1,"quiescent reset failed");
    $display("ok mailbox registered capture, held complete, stalls, exactly-once, quiescent reset");
    $finish;
  end
  initial begin #100us;$fatal(1,"timeout");end
endmodule
