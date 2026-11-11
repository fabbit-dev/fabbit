// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
`timescale 1ns / 1ps
// retro_sdram_calibrate + retro_sdram_train on the ESMT model with a held DQ bus and a
// fine phase shift model (672 steps per 15.52 ns period, PSDONE 12 clocks after PSEN, as
// MMCME2). Board: chip clock StartDelay after the controller edge, read flight DqInDelay.
// Physics window of the chip clock delay d: (T - tAC - DqIn, T) (tb_retro_sdram_train).
// Checks: the reported width matches the window within two points, the final delay is
// its middle within two points, center is the signed offset from the start phase,
// fail only for a window under MinSteps.
module tb_retro_sdram_calibrate;
    parameter realtime StartDelay = 4ns;
    parameter realtime DqInDelay = 3ns;
    parameter int MinSteps = 216;
    localparam realtime Period = 15.52ns;
    localparam int Steps = 672;
    logic clk = 0;
    always #(Period / 2) clk = !clk;

    // Fine phase shift: delay = StartDelay + shift * T / 672, wrapped into one period.
    int shift = 0;
    realtime sd_delay = StartDelay;
    function automatic realtime delay_of(input int sh);
        realtime d = StartDelay + sh * (Period / Steps);
        while (d >= Period) d -= Period;
        return d;
    endfunction
    logic sd_clk = 0;
    always @(posedge clk) fork automatic realtime d = sd_delay; #(d) sd_clk = 1; join_none
    always @(negedge clk) fork automatic realtime d = sd_delay; #(d) sd_clk = 0; join_none
    wire ps_en, ps_incdec;
    logic ps_done = 0;
    always @(posedge clk) begin
        ps_done <= 0;
        if (ps_en) fork
            begin
                repeat (12) @(posedge clk);
                shift = ps_incdec ? shift + 1 : shift - 1;
                sd_delay = delay_of(shift);
                ps_done <= 1;
            end
        join_none
    end

    logic reset = 1;
    wire train_run, train_idle, train_done, train_ok, done, fail;
    wire [9:0] width;
    wire signed [10:0] center;
    wire [10:0] sd_a;
    wire [1:0] sd_ba;
    wire sd_ras_n, sd_cas_n, sd_we_n, sd_dq_oe_next;
    wire [31:0] sd_dq_out;
    logic [31:0] sd_dq_in = 0;
    retro_sdram_train #(.Words(64), .PinCapture(3), .InitCycles(20)) train (
        .clk, .reset, .run(train_run), .idle(train_idle), .pass_done(train_done),
        .pass_ok(train_ok), .sd_a, .sd_ba, .sd_ras_n, .sd_cas_n, .sd_we_n, .sd_dq_out,
        .sd_dq_oe_next, .sd_dq_in);
    retro_sdram_calibrate #(.Period(Steps), .Step(8), .Passes(2), .MinSteps(MinSteps)) dut (
        .clk, .reset, .train_run, .train_idle, .train_done, .train_ok, .ps_en, .ps_incdec,
        .ps_done, .done, .fail, .width, .center);

    // Pad registers and the held-bus read path, as tb_retro_sdram_train.
    logic [31:0] pad_out = 0, pad_in = 0;
    logic pad_t = 1;
    always @(posedge clk) begin
        pad_out <= sd_dq_out; pad_t <= !sd_dq_oe_next; sd_dq_in <= pad_in;
    end
    tri [31:0] chip_dq;
    assign chip_dq = pad_t ? {32{1'bz}} : pad_out;
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

    initial begin
        real lo, hi, mid, got, step, want_w, want_c;
        repeat (4) @(posedge clk);
        reset = 0;
        do @(posedge clk); while (!done);
        step = Period / 1ns / Steps;
        lo = Period / 1ns - 8.0 - DqInDelay / 1ns;
        hi = Period / 1ns;
        mid = (lo + hi) / 2;
        got = sd_delay / 1ns;
        want_w = (hi - lo) / step;
        // offset from the start delay to the window middle, wrapped to (-T/2, T/2]
        want_c = mid - StartDelay / 1ns;
        while (want_c > Period / 1ns / 2) want_c -= Period / 1ns;
        while (want_c <= -Period / 1ns / 2) want_c += Period / 1ns;
        $display("window %0.2f..%0.2f ns, width %0d steps (physics %0.0f), fail %b",
                 lo, hi, width, want_w, fail);
        $display("delay %0.2f ns (mid %0.2f), center %0d steps (want %0.0f), shift %0d",
                 got, mid, center, want_c / step, shift);
        assert ((shift - int'(center)) % Steps == 0)
            else $fatal(1, "phase not at center: shift %0d center %0d", shift, center);
        assert (fail == (want_w < MinSteps - 16)) else $fatal(1, "fail flag");
        if (!fail) begin
            assert (width > want_w - 24 && width <= want_w + 8) else $fatal(1, "width");
            assert (got > mid - 0.4 && got < mid + 0.4) else $fatal(1, "not centered");
            assert (int'(center) > want_c / step - 16 && int'(center) < want_c / step + 16)
                else $fatal(1, "center offset");
        end
        assert (model.errors == 0) else $fatal(1, "model errors");
        $display("PASS calibration StartDelay %0.1f DqIn %0.1f", StartDelay / 1ns, DqInDelay / 1ns);
        $finish;
    end
    initial begin #400ms; $fatal(1, "timeout"); end
endmodule
`default_nettype wire
