`default_nettype none

// Shared MD/SNES raw-ROM path. NES is intentionally unavailable on this writer:
// it needs its legacy iNES parser/address mapping, not packed file bytes.
// One clock here; bus FIFO CDC/flush acknowledgements belong to the outer shell.
// Console memory ports are quiesced by run=0 and must drain while all_idle=0.
// Running is not itself a console proof; backend_valid must include successful
// mapper/header/IPL setup for the selected console before COMMIT.
module retro_loader (
    input  wire        clk,
    input  wire        rst,
    input  wire        begin_load,
    input  wire        abort_load,
    input  wire        commit_load,
    input  wire [1:0] system,
    input  wire [23:0] length,
    input  wire        all_idle,
    input  wire        fifo_empty,
    input  wire        init_ready,
    input  wire        backend_valid,
    input  wire        backend_fail,
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [7:0] in_data,
    output wire        flush_fifo,
    output wire        ready,
    output wire        loading,
    output wire        done,
    output wire        failed,
    output wire [2:0] run,
    output wire [1:0] selected,
    output wire [23:0] received,
    output wire        memory_idle,
    output wire        mem_valid,
    input  wire        mem_ready,
    output wire [20:0] mem_addr,
    output wire [31:0] mem_wdata,
    input  wire        mem_rsp_valid,
    output wire        mem_rsp_ready
);
  logic [23:0] length_q = '0;
  logic started = 1'b0;
  wire ctrl_ready, ctrl_valid, writer_ready, writer_in_ready, writer_done, writer_fail;
  wire [7:0] ctrl_data;
  wire start_writer = ctrl_ready && writer_ready && !started;
  always_ff @(posedge clk) begin
    if (rst || begin_load || abort_load) begin
      started <= 1'b0;
      if (begin_load) length_q <= length;
    end else if (start_writer) started <= 1'b1;
  end
  assign ready = ctrl_ready && started;
  retro_control #(.Systems(3'b110)) control (
      .clk(clk), .rst(rst), .begin_load(begin_load), .abort_load(abort_load),
      .commit_load(commit_load), .system(system), .length(length),
      .all_idle(all_idle && memory_idle), .fifo_empty(fifo_empty), .init_ready(init_ready),
      .in_valid(in_valid && started), .in_ready(in_ready), .in_data(in_data),
      .out_valid(ctrl_valid), .out_ready(writer_in_ready && started), .out_data(ctrl_data),
      .backend_done(started && writer_done && backend_valid),
      .backend_fail((started && writer_fail) || backend_fail), .flush_fifo(flush_fifo),
      .ready(ctrl_ready), .loading(loading), .done(done), .failed(failed), .run(run),
      .selected(selected), .received(received));
  retro_rom_writer writer (
      .clk(clk), .rst(rst), .start_valid(start_writer), .start_ready(writer_ready),
      .length(length_q), .base_word(21'd0),
      .abort_load(abort_load || begin_load || backend_fail),
      .in_valid(ctrl_valid), .in_ready(writer_in_ready), .in_data(ctrl_data), .idle(memory_idle),
      .done(writer_done), .failed(writer_fail), .received(), .mem_valid(mem_valid),
      .mem_ready(mem_ready), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
      .mem_rsp_valid(mem_rsp_valid), .mem_rsp_ready(mem_rsp_ready));
endmodule
