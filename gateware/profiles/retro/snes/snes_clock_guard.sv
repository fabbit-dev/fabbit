// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// Related clocks: service = 3*free_master, rising edges coincident (s0).
// free_master_ce is high in the service cycle before s0.
// The memory never holds the clock: core_hold only stops the whole console for
// stop/reset handshakes. permit updates on the s1 service edge (master high,
// 2 service periods before the next master rising edge) and is the BUFGCE CE.
module snes_clock_guard (
    input wire clk_service,
    input wire free_master,
    input wire free_master_ce,
    input wire reset,
    input wire running,
    input wire core_hold,
    output logic permit = 1'b1,
    output wire core_step,
    output wire clk_core
);
    logic at_s0 = 1'b0;
    always_ff @(posedge clk_service) begin
        at_s0 <= free_master_ce;
        if (at_s0) permit <= reset || !running || !core_hold;
    end
    assign core_step = free_master_ce && permit;
    // Simulation supplies a glitch-free negedge-latched model of this exact
    // primitive. Production always instantiates BUFGCE; no fabric clock AND.
    BUFGCE #(.SIM_DEVICE("7SERIES")) core_clock (
        .I(free_master), .CE(permit), .O(clk_core)
    );
endmodule
`default_nettype wire
