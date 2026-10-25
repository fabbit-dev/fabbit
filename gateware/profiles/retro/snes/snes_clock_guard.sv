// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// Related clocks: service = 4*free_master, rising edges coincident.
// free_master_ce is high only at that coincident service rising edge.
// Console outputs launch at edge0; memory samples at service edge1.
// permit updates ONLY at service falling edges during free_master HIGH:
// last decision at edge1.5, stable before master falling edge2 and throughout
// its low half. BUFGCE CE therefore has a half service period setup at master
// falling and 2.5 service periods before next rising. Constrain these related
// clocks/CE paths in the physical top; no timing exceptions asserted here.
//
// Whole clock is stopped, including ALL PPU/SCPU/SMP/DSP/RAM pipeline flops.
// Running/ENABLE/reset state does not change on a memory hold. The controller
// decides which edge must wait: a legal intermediate edge need not be blocked.
// Refresh/contention may still stretch master time; no nominal-rate guarantee.
module snes_clock_guard (
    input wire clk_service,
    input wire free_master,
    input wire free_master_ce,
    input wire reset,
    input wire running,
    input wire core_hold,
    output logic permit,
    output wire core_step,
    output wire clk_core
);
    always_ff @(negedge clk_service) begin
        if (free_master) permit <= reset || !running || !core_hold;
    end
    assign core_step = free_master_ce && permit;
    // Simulation supplies a glitch-free negedge-latched model of this exact
    // primitive. Production always instantiates BUFGCE; no fabric clock AND.
    BUFGCE #(.SIM_DEVICE("7SERIES")) core_clock (
        .I(free_master), .CE(permit), .O(clk_core)
    );
endmodule
`default_nettype wire
