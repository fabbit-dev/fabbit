// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
`timescale 1ns / 1ps
// retro_sdram_train against the ESMT model (tAC 8, tOH 2 ns, CL2) through pad registers
// and board delays. The DQ lines keep their last level when nobody drives them (bus
// capacitance, as on the board). The chip clock delay d sweeps one period in 0.25 ns
// steps. With a new word on DQ every clock, the trainer passes exactly where physics
// allows, so both window edges are asserted:
//  - data: word k is on the pad from (READ edge + d + T + tAC + DqIn) until word k+1
//    replaces it one period later; capture at READ+3T  =>  d > T - tAC - DqIn;
//  - commands: a command launched at an edge is taken by the chip edge d later, d < T.
// So the window is (T - tAC - DqIn, T): it moves with DqIn, and the trainer finds it.
module tb_retro_sdram_train;
    parameter realtime DqInDelay = 3ns;
    localparam realtime Period = 15.52ns;
    logic clk = 0;
    always #(Period / 2) clk = !clk;
    realtime sd_delay = 0;
    logic sd_clk = 0;
    // Transport delay: every edge kept even when the delay exceeds half a period.
    always @(posedge clk) fork automatic realtime d = sd_delay; #(d) sd_clk = 1; join_none
    always @(negedge clk) fork automatic realtime d = sd_delay; #(d) sd_clk = 0; join_none

    logic reset = 1, run = 0;
    wire idle, pass_done, pass_ok;
    wire [10:0] sd_a;
    wire [1:0] sd_ba;
    wire sd_ras_n, sd_cas_n, sd_we_n, sd_dq_oe_next;
    wire [31:0] sd_dq_out;
    logic [31:0] sd_dq_in = 0;
    retro_sdram_train #(.Words(64), .PinCapture(3), .InitCycles(20)) dut (.*);

    // Pad registers (retro_sdram_phy): ODDR data/tristate, IDDR capture.
    logic [31:0] pad_out = 0, pad_in = 0;
    logic pad_t = 1;
    always @(posedge clk) begin
        pad_out <= sd_dq_out; pad_t <= !sd_dq_oe_next; sd_dq_in <= pad_in;
    end
    tri [31:0] chip_dq;
    assign chip_dq = pad_t ? {32{1'bz}} : pad_out;
    // Read path: chip output -> held bus -> delay line -> pad.
    logic [31:0] held = 0;
    always @(chip_dq) for (int i = 0; i < 32; i++) if (chip_dq[i] !== 1'bz) held[i] = chip_dq[i];
    logic [31:0] line [64];
    initial begin
        foreach (line[i]) line[i] = 0;
        forever begin
            #0.25ns;
            for (int i = 63; i > 0; i--) line[i] = line[i-1];
            line[0] = held;
            pad_in = line[int'(DqInDelay / 0.25ns) - 1];
        end
    end
    sdram_model #(.TAc(8ns), .TOh(2ns), .TRcd(21ns)) model (
        .clk(sd_clk), .cke(1'b1), .cs_n(1'b0), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_we_n), .ba(sd_ba), .a(sd_a), .dqm(4'b0000), .dq(chip_dq));

    // Protocol monitor in chip clocks: tRCD 2, tRP 2, tRDL 2, tRFC 5, tRAS 3, tMRD 2.
    int cyc = 0, last_act = -100, last_pre = -100, last_wr = -100, last_ref = -100;
    int last_mrs = -100, last_rd = -100;
    bit open_row = 0;
    always @(posedge sd_clk) begin
        cyc++;
        case ({sd_ras_n, sd_cas_n, sd_we_n})
            3'b011: begin
                assert (!open_row && cyc - last_pre >= 2 && cyc - last_ref >= 5 &&
                        cyc - last_mrs >= 2) else $fatal(1, "ACT timing");
                open_row = 1; last_act = cyc;
            end
            3'b100, 3'b101: begin
                assert (open_row && cyc - last_act >= 2 && !sd_a[10])
                    else $fatal(1, "CAS timing");
                if (!sd_we_n) last_wr = cyc; else last_rd = cyc;
            end
            3'b010: begin
                assert (cyc - last_act >= 3 && cyc - last_wr >= 3) else $fatal(1, "PRE timing");
                open_row = 0; last_pre = cyc;
            end
            3'b001: begin
                assert (!open_row && cyc - last_pre >= 2 && cyc - last_ref >= 5)
                    else $fatal(1, "REF timing");
                last_ref = cyc;
            end
            3'b000: begin assert (!open_row) else $fatal(1, "MRS with open row"); last_mrs = cyc; end
            default: ;
        endcase
    end

    task automatic passes(input int n, output int ok);
        ok = 0;
        repeat (n) begin
            do @(posedge clk); while (!pass_done);
            if (pass_ok) ok++;
        end
    endtask

    initial begin
        int ok, first, last, width, runs;  // verilator lint_off WIDTH
        bit prev, in_win;
        repeat (4) @(posedge clk);
        reset = 0;
        do @(posedge clk); while (!idle);
        run = 1;
        first = -1; last = -1; width = 0; runs = 0; prev = 0;
        for (int i = 0; i < 62; i++) begin
            sd_delay = 0.125ns + i * 0.25ns;   // never exactly on an edge
            passes(1, ok);                       // settle on the new phase
            passes(2, ok);
            in_win = ok == 2;
            $display("delay %5.2f ns  %s", sd_delay, in_win ? "ok" : "X");
            if (in_win) begin
                width++;
                if (!prev) begin runs++; first = i; end
                last = i;
            end
            prev = in_win;
        end
        begin
            real lo, hi, want_lo, want_hi;
            lo = 0.125 + first * 0.25; hi = 0.125 + last * 0.25;
            want_lo = Period / 1ns - 8.0 - DqInDelay / 1ns;
            want_hi = Period / 1ns;
            // 0.5 ns: two sweep steps (0.25 ns delay-line grid plus the step itself).
            assert (runs == 1 && lo > want_lo && lo - want_lo <= 0.5 &&
                    hi < want_hi && want_hi - hi <= 0.5 && model.errors == 0)
                else $fatal(1, "window %0.3f..%0.3f, physics %0.3f..%0.3f, runs %0d",
                            lo, hi, want_lo, want_hi, runs);
            $display("PASS trainer window %0.3f..%0.3f ns (physics %0.2f..%0.2f), DqIn %0.1f ns",
                     lo, hi, want_lo, want_hi, DqInDelay / 1ns);
        end
        $finish;
    end
    initial begin #50ms; $fatal(1, "timeout"); end
endmodule
`default_nettype wire
