`default_nettype none
`timescale 1ns / 1ps
module tb_retro_mem_mux;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst = 1'b1;
  logic [1:0] owner = '0;
  wire idle;
  logic [1:0] req_valid = '0, req_write = '0, rsp_ready = '0;
  wire [1:0] req_ready, rsp_valid;
  logic [20:0] req_addr [2] = '{21'h12345, 21'h1ABCDE};
  logic [31:0] req_wdata [2] = '{32'h12345678, 32'hABCDEF01};
  logic [3:0] req_mask [2] = '{4'b0011, 4'b1100};
  wire [31:0] rsp_rdata;
  wire mem_valid, mem_write, mem_rsp_ready;
  wire [20:0] mem_addr;
  wire [31:0] mem_wdata;
  wire [3:0] mem_mask;
  logic mem_ready = 1'b0, mem_rsp_valid = 1'b0;
  logic [31:0] mem_rdata = '0;
  retro_mem_mux dut (.*);
  initial begin
    repeat (3) @(negedge clk);
    rst = 1'b0;
    req_valid = 2'b11;
    repeat (3) @(negedge clk);
    assert (req_ready == 0 && !mem_valid) else $fatal(1, "disabled owner");
    for (int i = 0; i < 2; i++) begin
      owner = 2'(i + 1);
      @(negedge clk);
      owner = 2'(2 - i);  // switch before downstream accepts: must preserve old payload
      assert (!idle && mem_valid && req_ready == 0 && mem_addr == req_addr[i] &&
              mem_wdata == req_wdata[i] && mem_mask == req_mask[i])
          else $fatal(1, "request snapshot");
      repeat (5) @(negedge clk);
      mem_ready = 1'b1;
      @(negedge clk);
      mem_ready = 1'b0;
      assert (!mem_valid && req_ready == 0 && rsp_valid == 0) else $fatal(1, "waiting response");
      mem_rdata = 32'h76543210 ^ 32'(i);
      mem_rsp_valid = 1'b1;
      #1;
      assert (rsp_valid == (2'b01 << i) && !mem_rsp_ready && rsp_rdata == mem_rdata)
          else $fatal(1, "response owner");
      // Other caller is ready: it must not consume the old response.
      rsp_ready = 2'b10 >> i;
      repeat (5) @(negedge clk);
      assert (!idle && !mem_rsp_ready) else $fatal(1, "response stolen");
      rsp_ready = 2'b01 << i;
      @(negedge clk);
      mem_rsp_valid = 1'b0;
      rsp_ready = '0;
      owner = 2'd0;
      assert (idle) else $fatal(1, "did not retire");
    end
    req_valid = '0;
    rst = 1'b1;
    @(negedge clk);
    assert (req_ready == 0 && rsp_valid == 0 && !mem_valid) else $fatal(1, "reset");
    $display("ok retro memory mux: owner snapshots, drain, disabled clients, backpressure");
    $finish;
  end
  initial begin
    #10us;
    $fatal(1, "timeout");
  end
endmodule
