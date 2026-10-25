// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// Free MD master services adapter even while emulated machine clocks are held.
// Stop: freeze both clock branches, wait sampling aperture, drain transaction,
// assert machine reset, then restore reset clocks. No reset cancels a live write.
module retro_md_machine (
    input wire clk,z80_clk,rst,run,loading,
    input wire [11:0] pad1,pad2,
    input wire [23:0] rom_words,
    output wire stopped,
    output wire req_valid,req_write,
    output wire [20:0] req_addr,
    output wire [31:0] req_wdata,
    output wire [3:0] req_mask,
    input wire req_ready,rsp_valid,
    output wire rsp_ready,
    input wire [31:0] rsp_rdata,
    output wire fault,
    output wire [3:0] red,green,blue,
    output wire pixel_ce,hs_n,vs_n,hde,vde,interlace,
    output wire [1:0] resolution,
    output wire [15:0] audio_l,audio_r
);
  typedef enum logic [1:0] {Stopped,Running,Drain,Resetting} state_t;
  state_t state=Stopped;
  logic [3:0] age=0;
  wire adapter_idle,core_clk,core_z80;
  logic freeze=0;
  wire core_reset=rst || state==Stopped || state==Resetting;
  always_ff @(negedge clk) freeze<=state==Drain && !rst;
  BUFGCE #(.SIM_DEVICE("7SERIES")) gate_master (.I(clk),.CE(!freeze),.O(core_clk));
  BUFGCE #(.SIM_DEVICE("7SERIES")) gate_z80 (.I(z80_clk),.CE(!freeze),.O(core_z80));
  always_ff @(posedge clk) begin
    if (rst) begin state<=Stopped;age<=0;end
    else case (state)
      Stopped: if (run && !loading) state<=Running;
      Running: if (!run) begin state<=Drain;age<=0;end
      Drain: if (age!=15) age<=age+1'b1;
             else if (adapter_idle) begin state<=Resetting;age<=0;end
      Resetting: if (age==15) state<=Stopped;else age<=age+1'b1;
      default: state<=Stopped;
    endcase
  end
  assign stopped=state==Stopped && adapter_idle;
  wire [23:0] addr;
  wire [15:0] wdata,rdata;
  wire [1:0] be;
  wire we,req,ack;
  retro_md_core core (.clk_master_i(core_clk),.clk_z80_i(core_z80),.reset_i(core_reset),
      .loading_i(loading),.pad1_i(pad1),.pad2_i(pad2),.rom_words_i(rom_words),
      .mem_addr_o(addr),.mem_wdata_o(wdata),.mem_be_o(be),.mem_we_o(we),.mem_req_o(req),
      .mem_ack_i(ack),.mem_rdata_i(rdata),.red_o(red),.green_o(green),.blue_o(blue),
      .pixel_ce_o(pixel_ce),.hs_n_o(hs_n),.vs_n_o(vs_n),.hde_o(hde),.vde_o(vde),
      .interlace_o(interlace),.field_o(),.resolution_o(resolution),
      .audio_left_o(audio_l),.audio_right_o(audio_r),.debug_m68k_addr_o(),.debug_vbus_addr_o());
  retro_md_memory adapter (.clk,.rst(core_reset),.enable(state==Running || state==Drain),
      .idle(adapter_idle),.fault,.mem_req(req),.mem_ack(ack),.mem_addr(addr),.mem_we(we),
      .mem_be(be),.mem_wdata(wdata),.mem_rdata(rdata),.req_valid,.req_ready,.req_write,
      .req_addr,.req_wdata,.req_mask,.rsp_valid,.rsp_ready,.rsp_rdata);
endmodule
`default_nettype wire
