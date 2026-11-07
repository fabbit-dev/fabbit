// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// Single-console image: one SDRAM controller, its own clock forwarded directly.
// Same owner/busy/settle contract as retro_sdram_owner, without any clock mux.
// Only the image's own system (or idle 0) can become owner; any other request
// stays blanked and busy, so no stale command reaches the chip.
module retro_sdram_single #(
    parameter logic [1:0] System = 2'd2,
    // 0: command/address go straight from the controller's own registers to the
    // pins, so they can pack into IOB output flops. Only for a controller that
    // itself drives NOP/zero address in reset (retro_sdram). DQ is always gated.
    parameter bit GateCommand = 1'b1
) (
    input wire clk, rst,
    input wire [1:0] requested,
    input wire safe,
    output logic [1:0] owner=0,
    output wire busy,
    input wire [10:0] a,
    input wire [1:0] ba,
    input wire [2:0] command,
    input wire [31:0] data,
    input wire drive,
    output wire [10:0] sd_a,
    output wire [1:0] sd_ba,
    output wire sd_ras_n,sd_cas_n,sd_we_n,
    output wire [31:0] dq_out,
    output wire dq_oe
);
  logic [5:0] settle=32;
  assign busy=rst || settle!=0 || requested!=owner;
  always_ff @(posedge clk)
    if (rst) begin owner<=0;settle<=32;end
    else if (settle!=0) settle<=settle-1'b1;
    else if (safe && requested!=owner && (requested==0 || requested==System)) begin
      owner<=requested;settle<=32;
    end
  // During controller reset the controller may retain its last registered
  // command. Never forward that stale WRITE/MRS to the chip.
  wire selected=owner==System && !busy && !safe;
  assign sd_a=selected || !GateCommand ? a : 0;
  assign sd_ba=selected || !GateCommand ? ba : 0;
  assign {sd_ras_n,sd_cas_n,sd_we_n}=selected || !GateCommand ? command : 3'b111;
  assign dq_out=selected ? data : 0;
  assign dq_oe=selected && drive;
endmodule
`default_nettype wire
