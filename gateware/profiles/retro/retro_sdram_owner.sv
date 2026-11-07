// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// Requested owner changes ONLY while all controllers reset and transaction-drained.
// Dedicated BUFGCTRLs switch between continuously running source clocks. Handover
// stretches a Low interval; its bound requires all source/management clocks live.
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
  typedef enum logic [2:0] {Idle, Plan, WaitOff, WaitOn, Commit, Settle} state_t;
  state_t state=Settle;
  logic [5:0] settle=32;
  logic [1:0] target=0, off_index=0, on_index=0;
  logic first_md=0, final_snes=0, reset_pending=0;
  // Bit order: first/NES, first/MD-memory, final/group, final/SNES-memory.
  localparam logic [3:0] InitialSelect=4'b0101;
  logic [3:0] select_command=InitialSelect;
  wire [3:0] select_line, select_ack;
  wire group_clock;
  wire nes_bridge,md_bridge,group_bridge,snes_bridge;
  wire [3:0] source_clock={snes_clock,group_clock,md_clock,nes_clock};
  for (genvar i=0;i<4;i++) begin : g_select
    wire desired;
    logic select_q=InitialSelect[i], acknowledged=InitialSelect[i];
    logic [2:0] age=0;
    sync_bit #(.Init(InitialSelect[i])) command_sync (
        .clk(source_clock[i]),.d(select_command[i]),.q(desired));
    // S is checked at its own incoming clock's FALLING edge (UG472 p45).
    // Launch on the rising edge, not the falling edge. No decode after this FF;
    // both max and min FF->S paths must remain timed, including bridge skew.
    always_ff @(posedge source_clock[i]) begin
      select_q<=desired;
      if (select_q!=desired) age<=0;
      else if (age!=7) age<=age+1'b1;
      else acknowledged<=select_q;
    end
    assign select_line[i]=select_q;
    // ACK changes only after eight complete local periods at the new S level.
    sync_bit #(.Init(InitialSelect[i])) ack_sync (
        .clk(clk),.d(acknowledged),.q(select_ack[i]));
  end
  assign busy=rst || reset_pending || state!=Idle || requested!=owner;
  // This bank has configuration INITs, but deliberately no runtime reset of
  // clock commands/handshakes. Finish an issued handover before returning to
  // idle/NES on reset; resetting one half would accept stale level ACKs.
  always_ff @(posedge clk) begin
    case (state)
      Idle: if (reset_pending || (safe && requested!=owner)) begin
        target<=reset_pending ? 2'd0 : requested;
        state<=Plan;
      end
      Plan: begin
        // Never change the first mux while a final handover is in flight.
        // Prepare the group clock BEFORE selecting it at the final mux.
        if (reset_pending && target!=0) target<=0;
        else if (target!=3 && first_md!=(target==2)) begin
          off_index<=first_md ? 2'd1 : 2'd0;
          on_index<=target==2 ? 2'd1 : 2'd0;
          select_command[first_md ? 1 : 0]<=0;
          state<=WaitOff;
        end else if (final_snes!=(target==3)) begin
          off_index<=final_snes ? 2'd3 : 2'd2;
          on_index<=target==3 ? 2'd3 : 2'd2;
          select_command[final_snes ? 3 : 2]<=0;
          state<=WaitOff;
        end else state<=Commit;
      end
      WaitOff: if (!select_ack[off_index]) begin
        select_command[on_index]<=1;
        state<=WaitOn;
      end
      WaitOn: if (select_ack[on_index]) begin
        if (on_index[1]) final_snes<=on_index[0];
        else first_md<=on_index[0];
        state<=Plan;
      end
      // A changed request never tears the captured target. If safe falls,
      // finish clock switching blanked, but do not expose a new payload owner.
      Commit: if (reset_pending && target!=0) begin target<=0;state<=Plan;end
      else if (safe || reset_pending) begin
        owner<=target;
        if (target==0) reset_pending<=0;
        settle<=32;
        state<=Settle;
      end
      Settle: if (settle!=0) settle<=settle-1'b1;
              else state<=Idle;
      default: state<=Idle;
    endcase
    // Reset blanks immediately at the output and commits owner zero here, but
    // never asynchronously resets any source-local S FF or its delayed ACK.
    if (rst) begin owner<=0;reset_pending<=1;end
  end
  // BUFH bridges use regional clock spines instead of requiring every edge of
  // this two-level mux tree to occupy cyclically adjacent global-buffer sites.
  // Switching remains in BUFGCTRL; there is no fabric clock mux or route waiver.
  BUFH nes_input_bridge (.I(nes_clock),.O(nes_bridge));
  BUFH md_input_bridge (.I(md_clock),.O(md_bridge));
  BUFH group_input_bridge (.I(group_clock),.O(group_bridge));
  BUFH snes_input_bridge (.I(snes_clock),.O(snes_bridge));
  BUFGCTRL #(.SIM_DEVICE("7SERIES")) first_mux (
      .I0(nes_bridge),.I1(md_bridge),.S0(select_line[0]),.S1(select_line[1]),
      .CE0(1'b1),.CE1(1'b1),.IGNORE0(1'b0),.IGNORE1(1'b0),.O(group_clock));
  BUFGCTRL #(.SIM_DEVICE("7SERIES")) final_mux (
      .I0(group_bridge),.I1(snes_bridge),.S0(select_line[2]),.S1(select_line[3]),
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
