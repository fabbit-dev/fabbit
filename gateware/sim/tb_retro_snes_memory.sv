// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
`timescale 1ns / 1ps
// Directed proof of snes_memory's 3:1 contract (no clock holds):
// requests launched at a master edge are sampled two service clocks later, read data
// is registered no later than master edge +4 (age <= 10 service clocks), posted
// writes commit, same-address read forwards the posted byte, a DMA read+write pair
// is served in one master period, overrun is reported. Refresh: with the S-CPU line
// pattern (40-master pause per 1364) every refresh fits the pause, no read is late and
// refresh_forced stays 0, even for a read at the first edge after the pause; without
// any pause the debt limit still refreshes in time and reports refresh_forced. Pad-register DQ (ODDR/IDDR) with board delays,
// conditional ESMT M12L64322A(2S)-7 CL2 model. Not a board signoff.
module tb_retro_snes_memory;
    parameter realtime SdDelay = 0.5ns;   // board flight of the forwarded clock
    parameter realtime DqInDelay = 5ns;   // board + input buffer + 2 ns IDELAY
    logic source = 0;
    always #23.28ns source = !source;
    wire service, master, memory_clock, locked, master_ce;
    retro_snes_clocks clocks (.clk_source(source), .reset(1'b0), .service, .master,
        .memory_clock, .idelay_ref(), .locked, .master_ce);
    logic reset = 1, enable = 0, cpu_refresh = 0;
    wire initialized, drained, core_hold, refresh_busy, refresh_forced, protocol_fault;
    wire [3:0] request_inflight, max_latency;
    wire [2:0] needs_data, deadline_fault, overrun_fault;
    logic [16:0] wram_addr = 0, save_addr = 0;
    logic [21:0] rom_addr = 0;
    logic [7:0] wram_data = 0, save_data = 0;
    logic wram_rd = 0, wram_wr = 0, rom_rd = 0, save_rd = 0, save_wr = 0;
    wire [7:0] wram_q, rom_q, save_q;
    wire wram_valid, wram_posted, wram_committed;
    wire rom_valid, save_valid, save_posted, save_committed;
    logic host_valid = 0, host_write = 0;
    logic [20:0] host_addr = 0;
    logic [31:0] host_wdata = 0;
    wire host_ready, host_done;
    wire [31:0] host_rdata;
    wire [10:0] sd_a;
    wire [1:0] sd_ba;
    wire sd_ras_n, sd_cas_n, sd_we_n, sd_cs_n, sd_cke, sd_dq_oe, sd_dq_oe_next;
    wire [31:0] sd_dq_out;
    wire [31:0] sd_dq_in;
    snes_memory #(.InitCycles(20)) dut (
        .clk(service), .master_ce, .free_ce(master_ce), .*);

    wire sd_clk;
    tri [31:0] chip_dq;
    retro_sdram_board #(.SdDelay(SdDelay), .DqInDelay(DqInDelay)) board (
        .clk_service(service), .memory_clock, .initialized, .sd_a, .sd_ba, .sd_ras_n,
        .sd_cas_n, .sd_we_n, .sd_cs_n, .sd_cke, .sd_dq_out, .sd_dq_oe_next, .sd_dq_in,
        .sd_clk, .chip_dq);
    // Refreshes issued while the console signals its quiet window.
    int refs_quiet = 0, refs_busy = 0, late_refs = 0, last_quiet = 0;
    bit line_phase = 0;
    always @(posedge sd_clk)
        if (!sd_cs_n && {sd_ras_n, sd_cas_n, sd_we_n} == 3'b001 && line_phase) begin
            if (cpu_refresh) refs_quiet++; else refs_busy++;
            if (cpu_refresh && int'(dut.quiet_edges) >= 36) late_refs++;
            if (cpu_refresh && int'(dut.quiet_edges) > last_quiet) last_quiet = int'(dut.quiet_edges);
        end
    always @(posedge service) assert (!core_hold) else $fatal(1, "clock hold");
    // One AUTO REFRESH owed exactly every RefreshInterval cycles (<= 15.625 us).
    int owe_last = -1, owe_cycle = 0, owe_periods = 0;
    always @(posedge service) begin
        owe_cycle++;
        if (dut.configured && dut.refresh_left == 0) begin
            if (owe_last >= 0) begin
                assert (owe_cycle - owe_last == dut.RefreshInterval &&
                        real'(dut.RefreshInterval) * 15.52 <= 15625.0)
                    else $fatal(1, "refresh owed every %0d cycles", owe_cycle - owe_last);
                owe_periods++;
            end
            owe_last = owe_cycle;
        end
    end
    int max_gap;
    always @(board.max_ref_gap) max_gap = board.max_ref_gap;

    task automatic tick; @(posedge service); #1ns; endtask
    // Console outputs change just after a master edge (s0); returns at s0+.
    task automatic edge_; @(posedge master); #1ns; endtask
    task automatic host(input bit wr, input logic [20:0] a, input logic [31:0] v);
        while (!host_ready) tick();
        @(negedge service);
        host_addr = a; host_write = wr; host_wdata = v; host_valid = 1;
        tick(); host_valid = 0;
        do tick(); while (!host_done);
        if (!wr) assert (host_rdata == v)
            else $fatal(1, "host %h got %h want %h", a, host_rdata, v);
    endtask
    // Check a level read issued at a master edge: data correct at master edge +4.
    task automatic expect_by_edge4(input int port, input logic [7:0] want);
        repeat (4) edge_();
        case (port)
            0: assert (wram_q == want) else $fatal(1, "WRAM q %h want %h", wram_q, want);
            1: assert (rom_q == want) else $fatal(1, "ROM q %h want %h", rom_q, want);
            2: assert (save_q == want) else $fatal(1, "save q %h want %h", save_q, want);
            default: ;
        endcase
    endtask
    initial begin
        while (!locked) #10ns;
        repeat (4) edge_();
        reset = 0;
        while (!initialized) tick();
        $display("PASS init CL2 BL1");
        host(1, 21'h000010, 32'h44332211);
        host(1, 21'h100020, 32'h5a5a5a5a);
        host(1, 21'h120030, 32'hc3c3c3c3);
        host(0, 21'h000010, 32'h44332211);
        host(0, 21'h100020, 32'h5a5a5a5a);
        $display("PASS host write/read through pad registers and board delays");
        while (!drained) tick();
        enable = 1;
        // ROM bytes in all four lanes.
        for (int l = 0; l < 4; l++) begin
            edge_(); rom_addr = 22'h40 + 22'(l); rom_rd = 1;
            expect_by_edge4(1, 8'h11 * 8'(l + 1));
            rom_rd = 0; repeat (2) edge_();
        end
        // WRAM read, save read.
        edge_(); wram_addr = 17'h20; wram_rd = 1; expect_by_edge4(0, 8'h5a); wram_rd = 0;
        edge_(); save_addr = 17'h30; save_rd = 1; expect_by_edge4(2, 8'hc3); save_rd = 0;
        repeat (2) edge_();
        $display("PASS ROM lanes / WRAM / save reads by master edge +4, max age %0d", max_latency);
        // Posted WRAM write, then a same-address read forwards before commit.
        edge_(); wram_addr = 17'h21; wram_data = 8'ha6; wram_wr = 1;
        edge_(); wram_wr = 0; wram_rd = 1;
        expect_by_edge4(0, 8'ha6); wram_rd = 0;
        repeat (4) edge_();
        // DMA pair: ROM read and WRAM write at the same edge, repeated every 8 masters.
        for (int i = 0; i < 16; i++) begin
            edge_(); rom_addr = 22'h40 + 22'(i % 4); rom_rd = 1;
            wram_addr = 17'h100 + 17'(i); wram_data = 8'(i * 7 + 1); wram_wr = 1;
            expect_by_edge4(1, 8'h11 * 8'(i % 4 + 1));
            rom_rd = 0; wram_wr = 0; repeat (4) edge_();
        end
        enable = 0;
        while (!drained) tick();
        host(0, 21'h100021, 32'ha6a6a6a6);
        for (int i = 0; i < 16; i++) host(0, 21'h100100 + 21'(i), {4{8'(i * 7 + 1)}});
        $display("PASS posted write forward, DMA read+write pairs, commits verified by host");
        // S-CPU line: 1364 masters, pause of 40 masters (cpu.v REFS_EXEC) at 100..139.
        // Fastest CPU reads every 6 masters outside it, the first one at the very first
        // edge after the pause (worst case for a REF issued late in the pause).
        // Sweep: lines of 336 masters (pause and timing as above) drift 0.67 master per
        // line against the 1006-cycle (335.33-master) refresh interval, so over 600 lines
        // a REF falls due at every edge of the pause, including its last allowed one.
        enable = 1; line_phase = 1;
        begin
        static int due = -1;
        static logic [7:0] want = 0;
        static int pos = 0, line = 0;
        static bit quiet, issue;
        for (int i = 0; i < 1364 * 120 + 336 * 600; i++) begin
            pos = pos == (i < 1364 * 120 ? 1363 : 335) ? 0 : pos + 1;
            if (pos == 0) line++;
            quiet = pos >= 100 && pos < 140;
            issue = pos >= 140 ? (pos - 140) % 6 == 0 && pos <= 330 + (i < 1364 * 120 ? 1028 : 0) :
                                  pos % 6 == 0 && pos < 100;
            edge_();
            if (i == due) assert (rom_q == want)
                else $fatal(1, "line read at master %0d (pos %0d): %h want %h", i, pos, rom_q, want);
            cpu_refresh = quiet;
            if (issue) begin
                rom_addr = 22'h40 + 22'(i % 4); rom_rd = 1;
                want = 8'h11 * 8'(i % 4 + 1); due = i + 4;
            end else if (i == due) rom_rd = 0;
        end
        end
        rom_rd = 0; cpu_refresh = 0; line_phase = 0;
        assert (refs_busy == 0) else $fatal(1, "%0d refreshes outside the pause", refs_busy);
        // Refresh in the pause never delays a read: the age stays the bare pipeline (7).
        // The pin shows a REF one cycle after the decision, when quiet_edges has already
        // counted the next pause edge: the last allowed decision is seen as QuietLast + 1.
        assert (last_quiet == dut.QuietLast + 1 && max_latency == 7)
            else $fatal(1, "latest REF at pause edge %0d (want %0d), age %0d", last_quiet,
                        dut.QuietLast + 1, max_latency);
        assert (deadline_fault == 0 && overrun_fault == 0 && !protocol_fault && !refresh_forced)
            else $fatal(1, "faults d=%b o=%b p=%b forced=%b", deadline_fault, overrun_fault,
                        protocol_fault, refresh_forced);
        assert (refs_quiet > 0 && board.refresh_rate_ok())
            else $fatal(1, "refresh %0d of %0d", board.refreshes, board.refreshes_needed());
        $display("PASS S-CPU line pattern: %0d refreshes all in the pause (%0d at its last edges, latest at pause edge %0d), need %0d, max gap %0d, max age %0d, not forced",
                 refs_quiet, late_refs, last_quiet, board.refreshes_needed(), max_gap, max_latency);
        // No pause at all (core without SNES_REFRESH): the debt limit still refreshes
        // within 125 us and reports it.
        for (int i = 0; i < 6000; i++) begin
            edge_(); rom_addr = 22'h40 + 22'(i % 4); rom_rd = 1;
            repeat (5) edge_(); rom_rd = 0;
        end
        assert (max_gap <= 8054 && refresh_forced) else $fatal(1, "forced refresh path");
        $display("PASS no pause: forced refresh, max gap %0d clocks, reported", max_gap);
        // Overrun: a different read before the previous one completed is reported.
        edge_(); rom_addr = 22'h41; rom_rd = 1;
        edge_(); rom_addr = 22'h80;
        repeat (3) edge_(); rom_rd = 0;
        assert (overrun_fault[1]) else $fatal(1, "overrun not reported");
        $display("PASS overrun reported");
        assert (owe_periods > 100) else $fatal(1, "refresh period not observed");
        $display("PASS refresh owed every %0d cycles (%0d periods checked)", dut.RefreshInterval,
                 owe_periods);
        $display("PASS snes_memory 3:1, no clock holds");
        $finish;
    end
    initial begin #400ms; $fatal(1, "timeout"); end
endmodule
`default_nettype wire
