// SPDX-License-Identifier: GPL-3.0-or-later
// No IPL firmware or silicon coefficient bytes are initialized here.
// All ports synchronous to clk. Hold run=0 while programming. reset clears
// validity, not RAM. ipl_clear/coeff_clear invalidate only the corresponding asset.
// Each address must be written once after clear; duplicate writes cannot mark
// an incomplete image ready. The host must verify provenance/length/hash itself.
module snes_assets (
    input logic clk,
    input logic reset,
    input logic run,
    input logic ipl_clear,
    input logic ipl_we,
    input logic [5:0] ipl_addr,
    input logic [7:0] ipl_data,
    input logic [5:0] ipl_read_addr,
    output logic [7:0] ipl_read_data,
    output logic ipl_ready,
    input logic coeff_clear,
    input logic coeff_we,
    input logic [8:0] coeff_addr,
    input logic [11:0] coeff_data,
    input logic [8:0] coeff_read_addr,
    output logic signed [11:0] coeff_read_data,
    output logic coeff_ready
);
    (* ram_style = "distributed" *) logic [7:0] ipl [64];
    (* ram_style = "distributed" *) logic [11:0] coeff [512];
    logic [63:0] ipl_written;
    logic [511:0] coeff_written;

    assign ipl_read_data = ipl[ipl_read_addr];
    assign coeff_read_data = coeff[coeff_read_addr];
    assign ipl_ready = &ipl_written;
    assign coeff_ready = &coeff_written;

    always_ff @(posedge clk) begin
        if (reset) begin
            ipl_written <= '0;
            coeff_written <= '0;
        end else if (!run) begin
            if (ipl_clear) ipl_written <= '0;
            else if (ipl_we) ipl_written[ipl_addr] <= 1'b1;
            if (coeff_clear) coeff_written <= '0;
            else if (coeff_we) coeff_written[coeff_addr] <= 1'b1;
        end
        if (!reset && !run && !ipl_clear && ipl_we) ipl[ipl_addr] <= ipl_data;
        if (!reset && !run && !coeff_clear && coeff_we) coeff[coeff_addr] <= coeff_data;
    end
endmodule
