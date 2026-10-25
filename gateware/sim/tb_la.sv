`timescale 1ns / 1ps
module tb_la;
  logic clk = 0;
  always #5 clk = ~clk;
  logic arm = 0;
  logic [7:0] probe = 8'h02;
  wire busy, tx;
  la_capture #(.Depth(4096), .Div(4)) u (.clk(clk), .arm(arm), .probe(probe), .busy(busy), .tx(tx));
  integer nbits = 0;
  initial begin
    #100 arm = 1; #10 arm = 0;
    #200 probe = 8'h00;  // CS# вниз
    #500 probe = 8'h05;
    wait (u.state == 3);  // Head
    $display("Head достигнут на %0t", $time);
    wait (u.state == 0);
    $display("выгрузка закончена на %0t", $time);
    $finish;
  end
  initial begin #5_000_000 $display("TIMEOUT state=%0d wa=%0d", u.state, u.wa); $finish; end
endmodule
