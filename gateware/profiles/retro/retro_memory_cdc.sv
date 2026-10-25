// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// One masked transaction across clock domains. Downstream response is buffered
// until source consumes it; idle covers both request and response retirement.
// No reset during a pending write: owner controller MUST wait idle first.
module retro_memory_cdc (
    input wire sclk, srst,
    input wire req_valid, req_write,
    input wire [20:0] req_addr,
    input wire [31:0] req_wdata,
    input wire [3:0] req_mask,
    output wire req_ready, rsp_valid,
    input wire rsp_ready,
    output wire [31:0] rsp_rdata,
    output wire idle,
    input wire dclk, drst,
    output wire mem_valid, mem_write,
    output wire [20:0] mem_addr,
    output wire [31:0] mem_wdata,
    output wire [3:0] mem_mask,
    input wire mem_ready, mem_rsp_valid,
    output wire mem_rsp_ready,
    input wire [31:0] mem_rdata
);
  wire pending, busy;
  wire [57:0] payload;
  logic issued=0;
  logic [31:0] result=0;
  logic consumed_source=0;
  wire ack_response;
  logic response=0;
  wire response_sync;
  sync_bit response_cdc (.clk(sclk), .d(response), .q(response_sync));
  assign req_ready=!srst && !busy && !response_sync;
  retro_mailbox #(.Width(58)) transaction (
      .sclk, .srst, .send(req_valid && req_ready),
      .data({req_write,req_addr,req_wdata,req_mask}), .busy,
      .dclk, .drst, .valid(pending), .received(payload), .complete(ack_response));
  assign {mem_write,mem_addr,mem_wdata,mem_mask}=payload;
  assign mem_valid=pending && !issued && !response;
  assign mem_rsp_ready=pending && issued && !response;
  assign rsp_valid=response_sync && !consumed_source;
  assign rsp_rdata=result;
  wire consumed;
  logic consumed_tgl=0, consumed_old=0;
  sync_bit consumed_cdc (.clk(dclk), .d(consumed_tgl), .q(consumed));
  assign ack_response=response && consumed!=consumed_old;
  assign idle=!busy && !response_sync;
  always_ff @(posedge sclk)
    if (srst) consumed_tgl<=0;
    else if (rsp_valid && rsp_ready) consumed_tgl<=~consumed_tgl;
  // Suppress repeated consumption until response falls after acknowledgement.
  // Source response-valid must be a single consumable event despite return CDC.
  // The explicit flag below is included in rsp_valid by the assignment below.
  always_ff @(posedge sclk)
    if (srst || !response_sync) consumed_source<=0;
    else if (rsp_valid && rsp_ready) consumed_source<=1;
  always_ff @(posedge dclk) begin
    if (drst) begin issued<=0; result<=0; response<=0; consumed_old<=0; end
    else begin
      if (mem_valid && mem_ready) issued<=1;
      if (mem_rsp_valid && mem_rsp_ready) begin result<=mem_rdata; response<=1; end
      if (ack_response) begin response<=0; issued<=0; consumed_old<=consumed; end
    end
  end
endmodule
`default_nettype wire
