// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// Requested owner changes ONLY while all controllers reset and transaction-drained.
// Clocks never stop: dedicated BUFGCTRLs switch between continuously running clocks.
// Command/DQ paths blank throughout settle; one physical DQ driver at top.
module retro_sdram_owner (
    input wire clk, rst,
    input wire [1:0] requested,
    input wire safe,
    output logic [1:0] owner=0,
    output wire busy,
    input wire nes_clock, md_clock, snes_clock,
    output wire memory_clock,
    input wire [10:0] a [3],
    input wire [1:0] ba [3],
    input wire [2:0] command [3],
    input wire [31:0] data [3],
    input wire [2:0] drive,
    output wire [10:0] sd_a,
    output wire [1:0] sd_ba,
    output wire sd_ras_n,sd_cas_n,sd_we_n,
    output wire [31:0] dq_out,
    output wire dq_oe
);
  logic [5:0] settle=0;
  wire group_clock;
  assign busy=settle!=0 || requested!=owner;
  always_ff @(posedge clk)
    if (rst) begin owner<=0;settle<=32;end
    else if (settle!=0) settle<=settle-1'b1;
    else if (safe && owner!=requested) begin owner<=requested;settle<=32;end
  BUFGCTRL #(.SIM_DEVICE("7SERIES")) first_mux (
      .I0(nes_clock),.I1(md_clock),.S0(owner!=2),.S1(owner==2),
      .CE0(1'b1),.CE1(1'b1),.IGNORE0(1'b0),.IGNORE1(1'b0),.O(group_clock));
  BUFGCTRL #(.SIM_DEVICE("7SERIES")) final_mux (
      .I0(group_clock),.I1(snes_clock),.S0(owner!=3),.S1(owner==3),
      .CE0(1'b1),.CE1(1'b1),.IGNORE0(1'b0),.IGNORE1(1'b0),.O(memory_clock));
  // During controller reset even a legacy controller may retain its last
  // registered command. Never forward that stale WRITE/MRS to the chip.
  wire selected=owner!=0 && !busy && !safe;
  wire [1:0] index=owner-1'b1;
  assign sd_a=selected ? a[index] : 0;
  assign sd_ba=selected ? ba[index] : 0;
  assign {sd_ras_n,sd_cas_n,sd_we_n}=selected ? command[index] : 3'b111;
  assign dq_out=selected ? data[index] : 0;
  assign dq_oe=selected && drive[index];
endmodule
`default_nettype wire
