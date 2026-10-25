// SPDX-License-Identifier: GPL-3.0-or-later
// Generic active-high pressed bits, serial order:
// [0:11] B,Y,Select,Start,Up,Down,Left,Right,A,X,L,R.
// Serial SNES line is active low; four trailing bits and disconnected line=1.
module snes_pad (
    input logic clk,
    input logic reset,
    input logic [11:0] buttons,
    input logic latch,
    input logic serial_clk,
    output logic [1:0] serial_data
);
    logic [15:0] shift;
    logic old_clk;
    assign serial_data = {1'b1, shift[0]};
    always_ff @(posedge clk) begin
        if (reset) begin
            shift <= '1;
            old_clk <= 1'b1;
        end else begin
            old_clk <= serial_clk;
            if (latch) shift <= {4'hf, ~buttons};
            else if (old_clk && !serial_clk) shift <= {1'b1, shift[15:1]};
        end
    end
endmodule
