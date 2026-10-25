`default_nettype none
`timescale 1ns / 1ps

module tb_retro_md_memory;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst = 1'b1, enable = 1'b0, mem_req = 1'b0, mem_we = 1'b0;
  logic [23:0] mem_addr = '0;
  logic [1:0] mem_be = '0;
  logic [15:0] mem_wdata = '0;
  wire idle, fault, mem_ack, req_valid, req_write, rsp_ready;
  wire [15:0] mem_rdata;
  wire [20:0] req_addr;
  wire [31:0] req_wdata;
  wire [3:0] req_mask;
  logic req_ready = 1'b0, rsp_valid = 1'b0;
  logic [31:0] rsp_rdata = '0;
  retro_md_memory dut (.*);
  int external_count = 0, completions = 0;
  always @(posedge clk) if (!rst && req_valid && req_ready) external_count++;

  task automatic transaction(input logic [24:0] address, input bit wr,
      input logic [1:0] be, input bit rejected, input bit drain, input bit noise);
    logic toggle, old_ack;
    logic [15:0] old_data;
    logic [24:0] physical;
    logic [31:0] expected_data;
    logic [3:0] expected_mask;
    int before_count;
    @(negedge clk);
    before_count = external_count;
    old_ack = mem_ack;
    old_data = mem_rdata;
    toggle = ~mem_ack;
    mem_req = toggle;
    mem_addr = address[24:1];
    mem_we = wr;
    mem_be = be;
    mem_wdata = 16'hA1B2;
    physical = address < 25'h0400000 ? address : address - 25'h0400000;
    expected_data = address[1] ? 32'hB2A10000 : 32'h0000B2A1;
    expected_mask = address[1] ? {be[0], be[1], 2'b00} : {2'b00, be[0], be[1]};
    @(negedge clk);  // captured, req_ready still low
    assert (!idle && mem_ack == old_ack) else $fatal(1, "early ack/capture");
    if (drain) enable = 1'b0;
    if (rejected) begin
      @(negedge clk);
      assert (idle && mem_ack == toggle && mem_rdata == 16'hFFFF && fault)
          else $fatal(1, "reject completion %h", address);
      assert (external_count == before_count && !req_valid)
          else $fatal(1, "rejected address reached memory");
    end else begin
      // Mutate even the input toggle while outstanding: ACK must use snapshot,
      // not current input. This is adversarial robustness, not a queued producer.
      for (int i = 0; i < 7; i++) begin
        if (noise) begin
          mem_req = 1'(i % 2);
          mem_addr = 24'hFFFFFF;
          mem_we = ~wr;
          mem_be = ~be;
          mem_wdata = 16'(i);
        end
        assert (req_valid && req_write == wr && req_addr == physical[22:2] &&
                req_wdata == expected_data && req_mask == expected_mask &&
                mem_ack == old_ack && mem_rdata == old_data && !rsp_ready)
            else $fatal(1, "stalled request changed address=%h", address);
        @(negedge clk);
      end
      req_ready = 1'b1;
      @(negedge clk);
      req_ready = 1'b0;
      assert (!req_valid && rsp_ready) else $fatal(1, "did not wait response");
      repeat (9) begin
        assert (mem_ack == old_ack && mem_rdata == old_data && !idle && !req_valid)
            else $fatal(1, "ack without response/duplicate issue");
        @(negedge clk);
      end
      // Leave live toggle DIFFERENT from captured toggle at response edge.
      if (noise) mem_req = ~toggle;
      rsp_rdata = 32'h78563412;
      rsp_valid = 1'b1;
      @(negedge clk);
      rsp_valid = 1'b0;
      assert (idle && mem_ack == toggle &&
              mem_rdata == (address[1] ? 16'h5678 : 16'h1234))
          else $fatal(1, "response endian/toggle %h", address);
      mem_req = toggle;  // restore before another edge; no phantom next request
      assert (external_count == before_count + 1) else $fatal(1, "not exactly once");
    end
    old_data = mem_rdata;
    repeat (3) begin
      @(negedge clk);
      assert (idle && !req_valid && mem_rdata == old_data && mem_ack == toggle)
          else $fatal(1, "held data/ack changed");
    end
    enable = 1'b1;
    completions++;
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst = 1'b0;
    // Disabled new toggle must remain pending without acceptance or fault.
    mem_req = 1'b1;
    repeat (5) @(negedge clk);
    assert (idle && !req_valid && !mem_ack && !fault) else $fatal(1, "disabled acceptance");
    mem_req = 1'b0;
    enable = 1'b1;
    // Every BE combination, each halfword, each mapped window; reads ignore BE.
    for (int window = 0; window < 3; window++)
      for (int halfword = 0; halfword < 2; halfword++)
        for (int mask = 0; mask < 4; mask++) begin
          automatic logic [24:0] base_addr = window == 0 ? 25'h0000000 :
                                                window == 1 ? 25'h0800000 : 25'h0820000;
          transaction(base_addr + 25'(halfword*2), 1'b0, 2'(mask), 0, 1, 1);
          transaction(base_addr + 25'(halfword*2), 1'b1, 2'(mask), window == 0, 1, 1);
        end
    // Both ends of all windows; immediately adjacent holes and high alias bits.
    transaction(25'h03FFFFE, 0, 0, 0, 0, 0);
    transaction(25'h080FFFE, 1, 3, 0, 0, 0);
    transaction(25'h083FFFE, 1, 3, 0, 0, 0);
    transaction(25'h0830000, 0, 0, 0, 0, 0);
    transaction(25'h0830002, 1, 1, 0, 0, 0);
    transaction(25'h0400000, 0, 3, 1, 0, 0);
    transaction(25'h07FFFFE, 1, 3, 1, 0, 0);
    transaction(25'h0810000, 0, 3, 1, 0, 0);
    transaction(25'h081FFFE, 1, 3, 1, 0, 0);
    transaction(25'h0840000, 0, 3, 1, 0, 0);
    transaction(25'h1000000, 1, 3, 1, 0, 0);
    transaction(25'h1800000, 0, 3, 1, 0, 0);
    transaction(25'h1FFFFFE, 1, 3, 1, 0, 0);
    assert (fault) else $fatal(1, "fault not sticky");
    // Reset only quiescent, together with producer toggle.
    @(negedge clk);
    rst = 1'b1;
    mem_req = 1'b0;
    @(negedge clk);
    rst = 1'b0;
    assert (idle && !fault && !mem_ack && mem_rdata == 0) else $fatal(1, "reset");
    // Three toggles at the earliest legal new edge. Last completion disables
    // the adapter in WaitResponse, then a new toggle waits for re-enable.
    for (int i = 0; i < 3; i++) begin
      automatic logic target = ~mem_ack;
      mem_req = target;
      mem_addr = 24'h400000;
      mem_we = 1'b0;
      req_ready = 1'b1;
      @(negedge clk);
      assert (req_valid && !idle) else $fatal(1, "fast toggle not captured");
      @(negedge clk);
      if (i == 2) enable = 1'b0;
      assert (rsp_ready && mem_ack != target) else $fatal(1, "fast toggle early ack");
      rsp_valid = 1'b1;
      rsp_rdata = 32'hDEADBEEF;
      @(negedge clk);
      rsp_valid = 1'b0;
      assert (mem_ack == target && idle && mem_rdata == 16'hEFBE)
          else $fatal(1, "fast toggle response");
      completions++;
    end
    req_ready = 1'b0;
    mem_req = ~mem_ack;
    repeat (4) @(negedge clk);
    assert (idle && !req_valid && mem_req != mem_ack) else $fatal(1, "disabled pending lost");
    enable = 1'b1;
    @(negedge clk);
    assert (req_valid) else $fatal(1, "re-enable not captured");
    req_ready = 1'b1;
    @(negedge clk);
    rsp_valid = 1'b1;
    @(negedge clk);
    rsp_valid = 1'b0;
    req_ready = 1'b0;
    completions++;
    assert (idle && mem_ack == mem_req && !fault) else $fatal(1, "re-enable response");
    $display("ok MD memory: %0d completions, %0d requests; masks/windows/bounds/drain/snapshot",
             completions, external_count);
    $finish;
  end
  initial begin
    #1ms;
    $fatal(1, "timeout");
  end
endmodule
