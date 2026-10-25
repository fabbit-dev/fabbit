// SPDX-License-Identifier: GPL-3.0-or-later
// The PPU has TWO independently addressed byte-wide 32 KiB banks, NOT two
// ports onto a 64 KiB byte array. A=low byte, B=high byte of a VRAM word.
// Ignore address bit 15 (the physical SNES VRAM word address is 15 bits).
// One rising-edge synchronous read, read-first; no reset/initial contents.
// PPU changes fetch address at its dot phase, consumes data at next dot phase.
module snes_vram (
    input logic clk,
    input logic enable,
    input logic [15:0] addr_a,
    input logic [15:0] addr_b,
    input logic [7:0] data_a,
    input logic [7:0] data_b,
    input logic we_a_n,
    input logic we_b_n,
    output logic [7:0] q_a,
    output logic [7:0] q_b
);
    (* ram_style = "block" *) logic [7:0] low_bank [32768];
    (* ram_style = "block" *) logic [7:0] high_bank [32768];
    always_ff @(posedge clk) begin
        q_a <= low_bank[addr_a[14:0]];
        q_b <= high_bank[addr_b[14:0]];
        if (enable && !we_a_n) low_bank[addr_a[14:0]] <= data_a;
        if (enable && !we_b_n) high_bank[addr_b[14:0]] <= data_b;
    end
endmodule
