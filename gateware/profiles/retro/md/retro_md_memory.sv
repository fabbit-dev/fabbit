// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none

// Same-clock MD MEM_REQ/MEM_ACK toggle -> masked request/response adapter.
// No CDC. One outstanding request: producer must hold its toggle/payload until
// ack equals that toggle. Snapshotting prevents duplicate issue or payload
// corruption while stalled; this is NOT a queue for pulses/multiple toggles.
// A toggle that flips twice before acceptance is unobservable and unsupported.
// A new toggle may be accepted on the edge after the previous acknowledgement.
//
// mem_addr is a 24-bit 16-bit WORD index, byte address = {mem_addr,1'b0}.
// Logical byte windows -> physical byte windows (all bounds inclusive):
// ROM 000000..3fffff -> 000000..3fffff, read only;
// WRAM 800000..80ffff -> 400000..40ffff;
// SRAM 820000..83ffff -> 420000..43ffff, volatile, no persistence.
// Decode all 25 byte-address bits BEFORE narrowing: no >8MiB silent alias.
// req_addr is a 21-bit 32-bit WORD index. Little-byte lanes preserve raw file
// order: first byte bits[7:0]. MD even byte is mem_wdata[15:8], enabled by
// mem_be[1]; odd byte is [7:0], enabled by mem_be[0]. Reads ignore mem_be.
// Invalid address or ANY ROM write (even BE=00) returns ffff and sets sticky
// fault, with a local ack and NO downstream request. Valid BE=00 writes still
// use downstream req/rsp; retro_mem_lanes implements their no-op completion.
// For accepted requests, ack changes ONLY after rsp_valid && rsp_ready; read
// data is registered at that same edge and held until the next completion.
// Backend must hold a response until rsp_ready (no unbuffered same-edge pulse
// response at request acceptance); this matches retro_mem_mux/retro_mem_lanes.
// enable gates ONLY new acceptance. Once captured, a transaction drains even
// with enable=0, including one stalled before downstream acceptance. idle=1
// means no captured transaction (an unaccepted disabled toggle may still wait).
// Before switching/reset: disable producer, disable adapter, wait idle and
// backend quiescent. rst resets this adapter AND core together, with quiescent
// backend; reset cannot undo an already accepted physical write.
module retro_md_memory (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,
    output wire        idle,
    output logic       fault = 1'b0,
    input  wire        mem_req,
    output logic       mem_ack = 1'b0,
    input  wire [23:0] mem_addr,
    input  wire        mem_we,
    input  wire [1:0]  mem_be,
    input  wire [15:0] mem_wdata,
    output logic [15:0] mem_rdata = '0,
    output wire        req_valid,
    input  wire        req_ready,
    output logic       req_write = 1'b0,
    output logic [20:0] req_addr = '0,
    output logic [31:0] req_wdata = '0,
    output logic [3:0] req_mask = '0,
    input  wire        rsp_valid,
    output wire        rsp_ready,
    input  wire [31:0] rsp_rdata
);
  timeunit 1ns;
  timeprecision 1ps;
  typedef enum logic [1:0] {Idle, Issue, WaitResponse, Reject} state_t;
  state_t state = Idle;
  logic pending_toggle = 1'b0, upper_half = 1'b0;
  wire [24:0] byte_addr = {mem_addr, 1'b0};
  wire rom = byte_addr < 25'h0400000;
  wire wram = byte_addr >= 25'h0800000 && byte_addr < 25'h0810000;
  wire sram = byte_addr >= 25'h0820000 && byte_addr < 25'h0840000;
  // Non-ROM windows subtract 4MiB. This expression is narrowed only after decode.
  wire [24:0] physical_byte = rom ? byte_addr : byte_addr - 25'h0400000;
  wire [15:0] read_half = upper_half ? rsp_rdata[31:16] : rsp_rdata[15:0];
  assign idle = state == Idle;
  assign req_valid = !rst && state == Issue;
  assign rsp_ready = !rst && state == WaitResponse;

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= Idle;
      fault <= 1'b0;
      mem_ack <= 1'b0;
      mem_rdata <= '0;
      pending_toggle <= 1'b0;
      upper_half <= 1'b0;
      req_write <= 1'b0;
      req_addr <= '0;
      req_wdata <= '0;
      req_mask <= '0;
    end else begin
      case (state)
        Idle: if (enable && mem_req != mem_ack) begin
          pending_toggle <= mem_req;
          upper_half <= mem_addr[0];
          req_write <= mem_we;
          req_addr <= physical_byte[22:2];
          req_wdata <= mem_addr[0] ? {mem_wdata[7:0], mem_wdata[15:8], 16'b0} :
                                                   {16'b0, mem_wdata[7:0], mem_wdata[15:8]};
          req_mask <= mem_addr[0] ? {mem_be[0], mem_be[1], 2'b00} :
                                                   {2'b00, mem_be[0], mem_be[1]};
          if (!(rom || wram || sram) || (rom && mem_we)) begin
            fault <= 1'b1;
            state <= Reject;
          end else state <= Issue;
        end
        Issue: if (req_ready) state <= WaitResponse;
        WaitResponse: if (rsp_valid) begin
          mem_rdata <= {read_half[7:0], read_half[15:8]};
          mem_ack <= pending_toggle;
          state <= Idle;
        end
        Reject: begin
          mem_rdata <= 16'hFFFF;
          mem_ack <= pending_toggle;
          state <= Idle;
        end
        default: state <= Idle;
      endcase
    end
  end
endmodule

`default_nettype wire
