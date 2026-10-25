`default_nettype none

// One-clock, one-outstanding transaction arbiter for selected console vs ROM loader.
// owner=0 disables requests, 1=console, 2=loader. Owner may change during a
// transaction: the latched RESPONSE owner does not. The old caller must still
// drain that response before it is reset. Switch controller waits for idle.
// Downstream is retro_mem_lanes (or another masked request/response backend).
module retro_mem_mux #(
    parameter int AddrBits = 21
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [1:0] owner,
    output wire        idle,
    input  wire [1:0] req_valid,
    output logic [1:0] req_ready,
    input  wire [1:0] req_write,
    input  wire [AddrBits-1:0] req_addr [2],
    input  wire [31:0] req_wdata [2],
    input  wire [3:0] req_mask [2],
    output logic [1:0] rsp_valid,
    input  wire [1:0] rsp_ready,
    output wire [31:0] rsp_rdata,
    output wire        mem_valid,
    input  wire        mem_ready,
    output wire        mem_write,
    output wire [AddrBits-1:0] mem_addr,
    output wire [31:0] mem_wdata,
    output wire [3:0] mem_mask,
    input  wire        mem_rsp_valid,
    output wire        mem_rsp_ready,
    input  wire [31:0] mem_rdata
);
  logic busy = 1'b0, pending_owner = 1'b0;
  // Stage the request as well as the response owner: owner may change while the
  // downstream ready is low, without changing its pending payload.
  logic issue = 1'b0, write_q = 1'b0;
  logic [AddrBits-1:0] addr_q = '0;
  logic [31:0] data_q = '0;
  logic [3:0] mask_q = '0;
  wire enabled = !rst && !busy && (owner == 2'd1 || owner == 2'd2);
  wire index = owner == 2'd2;
  assign idle = !busy;
  assign mem_valid = !rst && busy && issue;
  assign mem_write = write_q;
  assign mem_addr = addr_q;
  assign mem_wdata = data_q;
  assign mem_mask = mask_q;
  assign mem_rsp_ready = !rst && busy && !issue && rsp_ready[pending_owner];
  assign rsp_rdata = mem_rdata;
  always_comb begin
    req_ready = '0;
    rsp_valid = '0;
    if (enabled) req_ready[index] = 1'b1;
    if (!rst && busy && !issue) rsp_valid[pending_owner] = mem_rsp_valid;
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      busy <= 1'b0;
      issue <= 1'b0;
      pending_owner <= 1'b0;
    end else begin
      if (enabled && req_valid[index]) begin
        busy <= 1'b1;
        issue <= 1'b1;
        pending_owner <= index;
        write_q <= req_write[index];
        addr_q <= req_addr[index];
        data_q <= req_wdata[index];
        mask_q <= req_mask[index];
      end
      if (mem_valid && mem_ready) issue <= 1'b0;
      if (mem_rsp_valid && mem_rsp_ready) busy <= 1'b0;
    end
  end
endmodule
