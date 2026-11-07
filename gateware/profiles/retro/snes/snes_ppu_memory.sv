// SPDX-License-Identifier: GPL-3.0-or-later
// Portable replacements for Gowin generated CGRAM/OAM/HOAM primitives.
// Read-first, one-clock registered outputs. Port A is CPU, B is PPU.
// PPU port B writes are unused by this snapshot, but implemented here.
// verilog_lint: waive-start module-filename
module ppucgram (
    input logic clock,
    input logic [7:0] address_a, address_b,
    input logic [14:0] data_a, data_b,
    input logic wren_a, wren_b,
    output logic [14:0] q_a, q_b
);
    (* ram_style = "block" *) logic [14:0] mem [256];
    always @(posedge clock) begin
        q_a <= mem[address_a];
        if (wren_a) mem[address_a] <= data_a;
    end
    always @(posedge clock) begin
        q_b <= mem[address_b];
        if (wren_b) mem[address_b] <= data_b;
    end
endmodule

module ppuoam (
    input logic clock,
    input logic [7:0] address_a,
    input logic [6:0] address_b,
    input logic [15:0] data_a,
    input logic [31:0] data_b,
    input logic wren_a, wren_b,
    output logic [15:0] q_a,
    output logic [31:0] q_b
);
    (* ram_style = "block" *) logic [15:0] even_mem [128];
    (* ram_style = "block" *) logic [15:0] odd_mem [128];
    logic [15:0] even_q, odd_q;
    logic odd_select;
    assign q_a = odd_select ? odd_q : even_q;
    always @(posedge clock) begin
        odd_select <= address_a[0];
        even_q <= even_mem[address_a[7:1]];
        odd_q <= odd_mem[address_a[7:1]];
        if (wren_a && !address_a[0]) even_mem[address_a[7:1]] <= data_a;
        if (wren_a && address_a[0]) odd_mem[address_a[7:1]] <= data_a;
    end
    always @(posedge clock) begin
        q_b <= {odd_mem[address_b], even_mem[address_b]};
        if (wren_b) begin
            even_mem[address_b] <= data_b[15:0];
            odd_mem[address_b] <= data_b[31:16];
        end
    end
endmodule

module ppuhoam (
    input logic clock,
    input logic [4:0] address_a,
    input logic [6:0] address_b,
    input logic [7:0] data_a,
    input logic [1:0] data_b,
    input logic wren_a, wren_b,
    output logic [7:0] q_a,
    output logic [1:0] q_b
);
    logic [1:0] q_lane [4];
    logic [1:0] select_b;
    assign q_b = q_lane[select_b];
    always_ff @(posedge clock) select_b <= address_b[1:0];
    for (genvar lane = 0; lane < 4; lane++) begin : g_lanes
        (* ram_style = "distributed" *) logic [1:0] mem [32];
        always @(posedge clock) begin
            q_a[lane*2 +: 2] <= mem[address_a];
            if (wren_a) mem[address_a] <= data_a[lane*2 +: 2];
        end
        always @(posedge clock) begin
            q_lane[lane] <= mem[address_b[6:2]];
            if (wren_b && address_b[1:0] == 2'(lane)) mem[address_b[6:2]] <= data_b;
        end
    end
endmodule
// verilog_lint: waive-stop module-filename
