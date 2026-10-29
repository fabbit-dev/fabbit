`default_nettype none
`timescale 1ns / 1ps

// Real shared load path, no console model masquerading as a working console:
// control -> ROM writer -> ownership mux -> lanes/RMW -> physical SDRAM model.
module tb_retro_load;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  wire sd_clk;
  assign #2 sd_clk = clk;
  logic rst = 1'b1;
  logic begin_load = 1'b0, abort_load = 1'b0, commit_load = 1'b0;
  logic backend_valid = 1'b1, backend_fail = 1'b0;
  logic [1:0] system = '0;
  logic [23:0] length = '0;
  logic in_valid = 1'b0;
  logic [7:0] in_data = '0;
  wire in_ready, flush_fifo, ready, loading, done, failed;
  wire [2:0] run;
  wire [1:0] selected;
  wire [23:0] received;
  wire writer_idle, mux_idle, initialized;
  wire writer_mem_valid, writer_mem_ready, writer_mem_rsp, writer_mem_rsp_ready;
  wire [20:0] writer_addr;
  wire [31:0] writer_data;
  retro_loader loader (
      .clk(clk), .rst(rst), .begin_load(begin_load), .abort_load(abort_load),
      .commit_load(commit_load), .system(system), .length(length), .all_idle(mux_idle),
      .fifo_empty(1'b1), .init_ready(initialized), .in_valid(in_valid), .in_ready(in_ready),
      .in_data(in_data), .backend_valid(backend_valid), .backend_fail(backend_fail),
      .flush_fifo(flush_fifo),
      .ready(ready),
      .loading(loading), .done(done), .failed(failed), .run(run), .selected(selected),
      .received(received), .memory_idle(writer_idle), .mem_valid(writer_mem_valid),
      .mem_ready(writer_mem_ready), .mem_addr(writer_addr), .mem_wdata(writer_data),
      .mem_rsp_valid(writer_mem_rsp), .mem_rsp_ready(writer_mem_rsp_ready));

  logic console_req = 1'b0, console_write = 1'b0, console_rsp_ready = 1'b0;
  logic [20:0] console_addr = '0;
  logic [31:0] console_data = '0;
  logic [3:0] console_mask = '0;
  wire [1:0] client_ready, client_rsp;
  wire [31:0] client_data;
  wire mux_valid, mux_ready, mux_write, mux_rsp_valid, mux_rsp_ready;
  wire [20:0] mux_addr;
  wire [31:0] mux_data, mux_rdata;
  wire [3:0] mux_mask;
  assign writer_mem_ready = client_ready[1];
  assign writer_mem_rsp = client_rsp[1];
  retro_mem_mux mux (
      .clk(clk), .rst(rst), .owner(done ? 2'd1 : 2'd2), .idle(mux_idle),
      .req_valid({writer_mem_valid, console_req}), .req_ready(client_ready),
      .req_write({1'b1, console_write}), .req_addr('{console_addr, writer_addr}),
      .req_wdata('{console_data, writer_data}), .req_mask('{console_mask, 4'b1111}),
      .rsp_valid(client_rsp), .rsp_ready({writer_mem_rsp_ready, console_rsp_ready}),
      .rsp_rdata(client_data), .mem_valid(mux_valid), .mem_ready(mux_ready),
      .mem_write(mux_write), .mem_addr(mux_addr), .mem_wdata(mux_data), .mem_mask(mux_mask),
      .mem_rsp_valid(mux_rsp_valid), .mem_rsp_ready(mux_rsp_ready), .mem_rdata(mux_rdata));

  wire phys_valid, phys_ready, phys_write, phys_rsp_valid, phys_rsp_ready;
  wire [20:0] phys_addr;
  wire [31:0] phys_data, phys_rdata;
  retro_mem_lanes lanes (
      .clk(clk), .rst(rst), .req_valid(mux_valid), .req_ready(mux_ready), .req_write(mux_write),
      .req_addr(mux_addr), .req_wdata(mux_data), .req_mask(mux_mask), .rsp_valid(mux_rsp_valid),
      .rsp_ready(mux_rsp_ready), .rsp_rdata(mux_rdata), .mem_valid(phys_valid),
      .mem_ready(phys_ready), .mem_write(phys_write), .mem_addr(phys_addr),
      .mem_wdata(phys_data), .mem_rsp_valid(phys_rsp_valid), .mem_rsp_ready(phys_rsp_ready),
      .mem_rdata(phys_rdata));
  wire [10:0] sd_a;
  wire [1:0] sd_ba;
  wire sd_ras_n, sd_cas_n, sd_we_n;
  wire [31:0] sd_dq;
  wire [31:0] sd_dq_in, sd_dq_out;
  wire sd_dq_oe;
  retro_sdram_io io (.dq_in(sd_dq_in), .dq_out(sd_dq_out), .dq_oe(sd_dq_oe), .sd_dq(sd_dq));
  retro_sdram #(.InitCycles(20), .RefreshCycles(80)) memory (
      .clk(clk), .rst(rst), .initialized(initialized), .req_valid(phys_valid),
      .req_ready(phys_ready), .req_write(phys_write), .req_addr(phys_addr), .req_wdata(phys_data),
      .rsp_valid(phys_rsp_valid), .rsp_ready(phys_rsp_ready), .rsp_rdata(phys_rdata),
      .sd_a(sd_a), .sd_ba(sd_ba), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
      .sd_we_n(sd_we_n), .sd_dq_in(sd_dq_in), .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe), .sd_dq_oe_next());
  sdram_model model (.clk(sd_clk), .cke(1'b1), .cs_n(1'b0), .ras_n(sd_ras_n),
      .cas_n(sd_cas_n), .we_n(sd_we_n), .ba(sd_ba), .a(sd_a), .dqm(4'b0000), .dq(sd_dq));

  task automatic console_read(input logic [20:0] a, input logic [31:0] expect_data);
    console_addr = a;
    console_req = 1'b1;
    do @(posedge clk); while (!client_ready[0]);
    @(negedge clk);
    console_req = 1'b0;
    while (!client_rsp[0]) @(negedge clk);
    assert (client_data === expect_data) else $fatal(1, "loaded word mismatch");
    console_rsp_ready = 1'b1;
    @(negedge clk);
    console_rsp_ready = 1'b0;
  endtask
  initial begin
    repeat (3) @(negedge clk);
    rst = 1'b0;
    system = 2'd1;
    length = 24'd7;
    begin_load = 1'b1;
    @(negedge clk);
    begin_load = 1'b0;
    assert (failed && run == 0) else $fatal(1, "raw writer accepted iNES system");
    for (int s = 2; s <= 3; s++) begin
      logic [23:0] armed_length;
      armed_length = 24'd7;
      system = 2'(s);
      length = armed_length;
      begin_load = 1'b1;
      @(negedge clk);
      begin_load = 1'b0;
      // Metadata is shadowed at BEGIN; live CSR edits must not change payload size.
      length = 24'd1;
      while (!ready) @(negedge clk);
      for (int i = 0; i < 7; i++) begin
        in_valid = 1'b1;
        in_data = 8'(16*s + i);
        do @(posedge clk); while (!in_ready);
        @(negedge clk);
        in_valid = 1'b0;
      end
      while (!loader.writer_done) @(negedge clk);
      assert (received == 24'd7 && run == 0) else $fatal(1, "load boundary");
      commit_load = 1'b1;
      @(negedge clk);
      commit_load = 1'b0;
      assert (done && run == (3'b001 << (s-1))) else $fatal(1, "commit");
      console_read(21'd0, {8'(16*s+3), 8'(16*s+2), 8'(16*s+1), 8'(16*s)});
      console_read(21'd1, {8'hFF, 8'(16*s+6), 8'(16*s+5), 8'(16*s+4)});
      repeat (10) @(negedge clk);
      assert (done && received == armed_length && !writer_mem_valid)
          else $fatal(1, "writer restarted after DONE");
    end
    // Backend failure while the last accepted write is in flight must drain,
    // then a subsequent BEGIN must work (no writer stuck in Collect forever).
    system = 2'd2;
    length = 24'd1;
    begin_load = 1'b1;
    @(negedge clk);
    begin_load = 1'b0;
    while (!ready) @(negedge clk);
    in_valid = 1'b1;
    in_data = 8'hC7;
    do @(posedge clk); while (!in_ready);
    @(negedge clk);
    in_valid = 1'b0;
    backend_fail = 1'b1;
    @(negedge clk);
    backend_fail = 1'b0;
    while (!writer_idle || !mux_idle) @(negedge clk);
    assert (failed && run == 0) else $fatal(1, "backend failure did not revoke run");
    length = 24'd1;
    begin_load = 1'b1;
    @(negedge clk);
    begin_load = 1'b0;
    while (!ready) @(negedge clk);
    in_valid = 1'b1;
    in_data = 8'hA9;
    do @(posedge clk); while (!in_ready);
    @(negedge clk);
    in_valid = 1'b0;
    while (!loader.writer_done) @(negedge clk);
    commit_load = 1'b1;
    @(negedge clk);
    commit_load = 1'b0;
    assert (done && run == 3'b010) else $fatal(1, "failure recovery did not restart");
    console_read(21'd0, 32'hFFFFFFA9);
    assert (model.errors == 0) else $fatal(1, "SDRAM model errors");
    $display("ok retro load: MD/SNES control/writer/mux/RMW/SDRAM, reject NES raw, no FPGA reload");
    $finish;
  end
  initial begin
    #100us;
    $fatal(1, "timeout");
  end
endmodule
