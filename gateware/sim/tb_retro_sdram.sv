`default_nettype none
`timescale 1ns / 1ps

module tb_retro_sdram #(
    parameter int TrcdCycles = 2,
    parameter int TrasCycles = 5,
    parameter int HalfPeriodNs = 5
);
  logic clk = 1'b0;
  always #(HalfPeriodNs * 1ns) clk = ~clk;
  wire sd_clk;
  assign #2 sd_clk = clk;  // selected test phase, NOT board calibration
  logic rst = 1'b1;
  logic req_valid = 1'b0, req_write = 1'b0, rsp_ready = 1'b0;
  logic [20:0] req_addr = '0;
  logic [31:0] req_wdata = '0;
  logic [3:0] req_mask = '0;
  wire req_ready, rsp_valid;
  wire [31:0] rsp_rdata;
  wire mem_valid, mem_ready, mem_write, mem_rsp_valid, mem_rsp_ready;
  wire [20:0] mem_addr;
  wire [31:0] mem_wdata, mem_rdata;
  wire initialized, sd_ras_n, sd_cas_n, sd_we_n;
  wire [10:0] sd_a;
  wire [1:0] sd_ba;
  wire [31:0] sd_dq;
  wire [31:0] sd_dq_in, sd_dq_out;
  wire sd_dq_oe;
  retro_sdram_io io (.dq_in(sd_dq_in), .dq_out(sd_dq_out), .dq_oe(sd_dq_oe), .sd_dq(sd_dq));
  retro_mem_lanes lanes (.*);
  retro_sdram #(.InitCycles(20), .RefreshCycles(80), .Trcd(TrcdCycles), .Tras(TrasCycles)) dut (
      .clk(clk), .rst(rst), .initialized(initialized), .req_valid(mem_valid),
      .req_ready(mem_ready), .req_write(mem_write), .req_addr(mem_addr), .req_wdata(mem_wdata),
      .rsp_valid(mem_rsp_valid), .rsp_ready(mem_rsp_ready), .rsp_rdata(mem_rdata),
      .sd_a(sd_a), .sd_ba(sd_ba), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
      .sd_we_n(sd_we_n), .sd_dq_in(sd_dq_in), .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe), .sd_dq_oe_next());
  sdram_model model (.clk(sd_clk), .cke(1'b1), .cs_n(1'b0), .ras_n(sd_ras_n),
      .cas_n(sd_cas_n), .we_n(sd_we_n), .ba(sd_ba), .a(sd_a), .dqm(4'b0000), .dq(sd_dq));

  int cycle = 0, refreshes = 0, last_ref = -1000;
  int last_act [4] = '{-1000, -1000, -1000, -1000};
  int last_pre [4] = '{-1000, -1000, -1000, -1000};
  int last_write [4] = '{-1000, -1000, -1000, -1000};
  always @(posedge sd_clk) begin
    cycle++;
    case ({sd_ras_n, sd_cas_n, sd_we_n})
      3'b011: begin
        assert (cycle - last_pre[sd_ba] >= 2 && cycle - last_ref >= 7)
            else $fatal(1, "ACT violates tRP/tRFC");
        last_act[sd_ba] = cycle;
      end
      3'b100: last_write[sd_ba] = cycle;
      3'b010: begin
        for (int b = 0; b < 4; b++) if (sd_a[10] || 2'(b) == sd_ba) begin
          assert (cycle - last_act[b] >= TrasCycles && cycle - last_write[b] >= 2)
              else $fatal(1, "PRE violates tRAS/tWR");
          last_pre[b] = cycle;
        end
      end
      3'b001: begin
        for (int b = 0; b < 4; b++)
          assert (cycle - last_pre[b] >= 2) else $fatal(1, "REF violates tRP");
        assert (cycle - last_ref >= 7) else $fatal(1, "REF violates tRFC");
        last_ref = cycle;
        refreshes++;
      end
      default: ;
    endcase
    if (initialized)
      assert (cycle - last_ref < 120) else $fatal(1, "refresh starved");
  end

  logic [31:0] expected [64];
  function automatic logic [20:0] address(input int i);
    // All banks, both row/column boundaries, high row/address bits.
    return {2'(i % 4), 11'(i * 71), 8'(i * 37)};
  endfunction
  task automatic request(input bit wr, input int i, input logic [31:0] data,
                         input logic [3:0] mask);
    @(negedge clk);
    req_valid = 1'b1;
    req_write = wr;
    req_addr = address(i);
    req_wdata = data;
    req_mask = mask;
    do @(posedge clk); while (!req_ready);
    @(negedge clk);
    req_valid = 1'b0;
    while (!rsp_valid) @(negedge clk);
    if (wr) begin
      for (int b = 0; b < 4; b++) if (mask[b]) expected[i][b*8+:8] = data[b*8+:8];
    end else begin
      assert (rsp_rdata === expected[i])
          else $fatal(1, "readback addr=%h got=%h want=%h", address(i), rsp_rdata, expected[i]);
    end
    // Backpressure longer than tREFI: refresh must continue with response pending.
    repeat (100) @(negedge clk);
    assert (rsp_valid) else $fatal(1, "lost stalled response");
    rsp_ready = 1'b1;
    @(negedge clk);
    rsp_ready = 1'b0;
  endtask
  initial begin
    repeat (4) @(negedge clk);
    rst = 1'b0;
    while (!initialized) begin
      assert (!mem_ready) else $fatal(1, "request before init");
      @(negedge clk);
    end
    for (int i = 0; i < 64; i++) request(1'b1, i, 32'h1234ABCD ^ 32'(i), 4'b1111);
    for (int i = 0; i < 64; i++) begin
      request(1'b1, i, 32'hF9876543 ^ 32'(i), 4'(i % 16));
      request(1'b0, i, '0, '0);
    end
    assert (refreshes > 100 && model.errors == 0)
        else $fatal(1, "refresh/model errors refs=%d errors=%d", refreshes, model.errors);
    $display("ok retro SDRAM: all banks/rows/columns, DQM=0 RMW masks, refresh under stalls");
    $finish;
  end
  initial begin
    #1ms;
    $fatal(1, "timeout");
  end
endmodule
