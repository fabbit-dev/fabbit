// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// SPC700/DSP audio RAM, 64 KiB in block RAM on the console clock. One rising-edge
// synchronous read (data after one edge; the console's contract allows two),
// writes while the level strobe is high (idempotent). Keeping ARAM on chip removes
// the APU's request stream from SDRAM, which leaves the CPU's own DRAM refresh
// pause free for SDRAM auto refresh. No reset/initial contents (power-on RAM).
module snes_aram (
    input wire clk,
    input wire [15:0] addr,
    input wire [7:0] data,
    input wire rd, wr,
    output logic [7:0] q
);
    (* ram_style = "block" *) logic [7:0] ram [65536];
    always_ff @(posedge clk) begin
        q <= ram[addr];
        if (wr) ram[addr] <= data;
    end
endmodule
`default_nettype wire
