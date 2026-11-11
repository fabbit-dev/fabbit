// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
`timescale 1ns / 1ps
// Board model shared by the SNES memory benches: pad registers of retro_sdram_phy,
// PCB flight, ESMT M12L64322A(2S)-7 CL2 chip model and an independent protocol monitor.
//  - Commands and DQ out reach the chip at the controller edge (ODDR, short traces).
//  - Chip clock = memory_clock + SdDelay (forwarded clock flight).
//  - Read data reaches the FPGA pad DqInDelay after the chip drives it (flight, buffers,
//    IDELAY). Transport delay line of 0.5 ns taps keeps every edge. Released DQ lines
//    hold their last level, so only a new word on the next clock ends a read's data.
// Monitor (chip clock cycles of 15.52 ns, datasheet Rev1.0 pp6-7): tMRD 2, tRFC 5, tRC 5,
// tRRD 1, tRCD 2, autoprecharge (tRAS 3 + tRP 2, write tRDL 2) or an open row closed by
// PRE (tRAS 3, tRDL 2, then tRP 2), no DQ contention, at most 8 consecutive AUTO
// REFRESH, any refresh interval <= 8 x 15.6 us = 8054 clocks once initialized.
// Statistics are public for the benches. Not a board signoff: delays are assumptions.
module retro_sdram_board #(
    parameter realtime SdDelay = 0.5ns,
    parameter realtime DqInDelay = 5ns
) (
    input  wire        clk_service,      // controller and pad register clock
    input  wire        memory_clock,     // forwarded SDRAM clock before the board
    input  wire        initialized,      // controller finished init: refresh rules apply
    input  wire [10:0] sd_a,
    input  wire  [1:0] sd_ba,
    input  wire        sd_ras_n, sd_cas_n, sd_we_n, sd_cs_n, sd_cke,
    input  wire [31:0] sd_dq_out,
    input  wire        sd_dq_oe_next,
    output logic [31:0] sd_dq_in = 0,
    output wire        sd_clk,
    output tri  [31:0] chip_dq
);
    // Pad registers: ODDR data + tristate, IDDR Q1 capture.
    logic [31:0] pad_out = 0, pad_in = 0;
    logic pad_t = 1;
    always @(posedge clk_service) begin
        pad_out <= sd_dq_out;
        pad_t <= !sd_dq_oe_next;
        sd_dq_in <= pad_in;
    end
    assign chip_dq = pad_t ? {32{1'bz}} : pad_out;

    // DQ lines keep the last driven level when released (bus capacitance, measured on
    // the board: diag retro_sdram_eye_snes3_late passes at READ+4).
    logic [31:0] held = 0;
    always @(chip_dq)
        for (int i = 0; i < 32; i++) if (chip_dq[i] !== 1'bz) held[i] = chip_dq[i];
    localparam int Taps = 64;
    initial assert (DqInDelay >= 0.5ns && DqInDelay <= Taps * 0.5ns)
        else $fatal(1, "DqInDelay out of the delay line");
    logic [31:0] line [Taps];
    initial begin
        foreach (line[i]) line[i] = 0;
        forever begin
            #0.5ns;
            for (int i = Taps - 1; i > 0; i--) line[i] = line[i - 1];
            line[0] = held;
            pad_in = line[int'(DqInDelay / 0.5ns) - 1];
        end
    end

    assign #(SdDelay) sd_clk = memory_clock;
    sdram_model #(.TAc(8ns), .TOh(2ns), .TRcd(21ns)) model (
        .clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_we_n), .ba(sd_ba), .a(sd_a), .dqm(4'b0000), .dq(chip_dq));

    int cycle = 0, last_ref = -100000, last_mrs = -1000, last_any_act = -1000;
    int last_act [4] = '{-1000, -1000, -1000, -1000};
    int busy_until [4] = '{-1000, -1000, -1000, -1000};
    int last_wr [4] = '{-1000, -1000, -1000, -1000};
    bit open_row [4] = '{0, 0, 0, 0};
    int refreshes = 0, first_ref = 0, max_ref_gap = 0, burst = 0, max_burst = 0;
    int reads = 0, writes = 0;
    always @(posedge sd_clk) begin
        cycle++;
        if (!sd_cs_n) case ({sd_ras_n, sd_cas_n, sd_we_n})
            3'b000: begin
                assert (sd_a == 11'h020) else $fatal(1, "mode not CL2 BL1");
                for (int b = 0; b < 4; b++)
                    assert (!open_row[b] && cycle >= busy_until[b]) else $fatal(1, "MRS bank busy");
                last_mrs = cycle;
            end
            3'b011: begin
                assert (cycle - last_mrs >= 2 && cycle - last_ref >= 5 && !open_row[sd_ba] &&
                        cycle >= busy_until[sd_ba] && cycle - last_any_act >= 1)
                    else $fatal(1, "ACT tMRD/tRFC/tRP/tRC/tRRD bank %0d", sd_ba);
                last_act[sd_ba] = cycle; last_any_act = cycle; open_row[sd_ba] = 1;
            end
            3'b101, 3'b100: begin
                assert (open_row[sd_ba] && cycle - last_act[sd_ba] >= 2) else $fatal(1, "tRCD");
                if (!sd_we_n) last_wr[sd_ba] = cycle;
                if (!sd_we_n) begin
                    assert (!model.dq_e && chip_dq !== 32'hzzzzzzzz)
                        else $fatal(1, "write DQ contention or undriven");
                    writes++;
                end else reads++;
                // Autoprecharge: tRAS 3 from ACT, then tRP 2; a write adds tRDL 2.
                if (sd_a[10]) begin
                    open_row[sd_ba] = 0;
                    busy_until[sd_ba] = (sd_we_n ? cycle + 1 : cycle + 2) + 2;
                    if (busy_until[sd_ba] < last_act[sd_ba] + 5)
                        busy_until[sd_ba] = last_act[sd_ba] + 5;
                end
            end
            3'b010: for (int b = 0; b < 4; b++) if (sd_a[10] || sd_ba == 2'(b)) begin
                if (open_row[b])
                    assert (cycle - last_act[b] >= 3 && cycle - last_wr[b] >= 2)
                        else $fatal(1, "PRE tRAS/tRDL bank %0d", b);
                open_row[b] = 0;
                if (busy_until[b] < cycle + 2) busy_until[b] = cycle + 2;
            end
            3'b001: begin
                for (int b = 0; b < 4; b++)
                    assert (cycle >= busy_until[b] && !open_row[b]) else $fatal(1, "REF bank busy");
                assert (cycle - last_ref >= 5) else $fatal(1, "tRFC");
                if (initialized) begin
                    if (first_ref == 0) first_ref = cycle;
                    else if (cycle - last_ref > max_ref_gap) max_ref_gap = cycle - last_ref;
                    burst = cycle - last_ref <= 6 ? burst + 1 : 1;
                    if (burst > max_burst) max_burst = burst;
                    refreshes++;
                end
                last_ref = cycle;
            end
            default: ;
        endcase
        if (initialized && first_ref > 0) begin
            assert (cycle - last_ref <= 8054) else $fatal(1, "refresh interval > 125 us");
            assert (max_burst <= 8) else $fatal(1, "more than 8 consecutive refreshes");
        end
    end
    always @(posedge clk_service) assert (model.errors == 0)
        else $fatal(1, "SDRAM model errors %0d", model.errors);

    // AUTO REFRESH owed by the 4096 per 64 ms average since the first one.
    function automatic int refreshes_needed();
        return first_ref == 0 ? 0 : (cycle - first_ref) / 1006;
    endfunction
    // Average met: at most 8 postponed AUTO REFRESH (ESMT) are still owed. Over a long
    // run a rate even 0.1 % too slow exceeds this (deficit grows with time).
    function automatic bit refresh_rate_ok();
        return refreshes + 8 >= refreshes_needed();
    endfunction
endmodule
