// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
`timescale 1ns / 1ps
// Directed proof of snes_memory's 3:1 contract (no clock holds):
// requests launched at a master edge are sampled two service clocks later, read data
// is registered no later than master edge +4 (age <= 10 service clocks), posted
// writes commit, same-address read forwards the posted byte, a DMA read+write pair
// is served in one master period, overrun is reported, refresh uses the console's
// quiet window and never starves. Pad-register DQ (ODDR/IDDR) with board delays,
// conditional ESMT M12L64322A(2S)-7 CL2 model. Not a board signoff.
module tb_retro_snes_memory;
    parameter realtime SdDelay = 0.5ns;   // board flight of the forwarded clock
    parameter realtime DqInDelay = 5ns;   // board + input buffer + 2 ns IDELAY
    logic source = 0;
    always #23.28ns source = !source;
    wire service, master, memory_clock, locked, master_ce;
    retro_snes_clocks clocks (.clk_source(source), .reset(1'b0), .service, .master,
        .memory_clock, .idelay_ref(), .locked, .master_ce);
    logic reset = 1, enable = 0, refresh_now = 0, cpu_refresh = 0;
    wire initialized, drained, core_hold, refresh_busy, protocol_fault;
    wire [4:0] request_inflight;
    wire [3:0] needs_data, deadline_fault, overrun_fault, max_latency;
    logic [16:0] wram_addr = 0, save_addr = 0;
    logic [15:0] aram_addr = 0;
    logic [21:0] rom_addr = 0;
    logic [7:0] wram_data = 0, aram_data = 0, save_data = 0;
    logic wram_rd = 0, wram_wr = 0, aram_rd = 0, aram_wr = 0, rom_rd = 0, save_rd = 0, save_wr = 0;
    wire [7:0] wram_q, aram_q, rom_q, save_q;
    wire wram_valid, wram_posted, wram_committed, aram_valid, aram_posted, aram_committed;
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
    logic [31:0] sd_dq_in = 0;
    snes_memory #(.InitCycles(20), .RefreshCycles(900)) dut (
        .clk(service), .master_ce, .free_ce(master_ce), .*);

    // Pad registers + board: as tb_retro_snes_game.
    logic [31:0] pad_out = 0, pad_in = 0;
    logic pad_t = 1;
    always @(posedge service) begin
        pad_out <= sd_dq_out; pad_t <= !sd_dq_oe_next; sd_dq_in <= pad_in;
    end
    tri [31:0] chip_dq;
    assign chip_dq = pad_t ? {32{1'bz}} : pad_out;
    logic [31:0] line [64];
    initial begin
        foreach (line[i]) line[i] = 0;
        forever begin
            #0.5ns;
            for (int i = 63; i > 0; i--) line[i] = line[i-1];
            line[0] = chip_dq;
            pad_in = line[int'(DqInDelay / 0.5ns) - 1];
        end
    end
    wire sd_clk;
    assign #(SdDelay) sd_clk = memory_clock;
    sdram_model #(.TAc(8ns), .TOh(2ns), .TRcd(21ns)) model (
        .clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_we_n), .ba(sd_ba), .a(sd_a), .dqm(4'b0000), .dq(chip_dq));

    // Protocol monitor (chip clock cycles of 15.52 ns).
    int cyc = 0, last_ref = -100000, last_mrs = -1000, last_any_act = -1000;
    int last_act [4] = '{-1000, -1000, -1000, -1000};
    int busy_until [4] = '{-1000, -1000, -1000, -1000};
    int refs = 0, max_gap = 0, refs_quiet = 0;
    always @(posedge sd_clk) begin
        cyc++;
        if (!sd_cs_n) case ({sd_ras_n, sd_cas_n, sd_we_n})
            3'b000: begin
                assert (sd_a == 11'h020) else $fatal(1, "mode not CL2 BL1");
                last_mrs = cyc;
            end
            3'b011: begin
                assert (cyc - last_mrs >= 2 && cyc - last_ref >= 5 &&
                        cyc >= busy_until[sd_ba] && cyc - last_any_act >= 1)
                    else $fatal(1, "ACT tMRD/tRFC/tRP/tRC");
                last_act[sd_ba] = cyc; last_any_act = cyc;
            end
            3'b101, 3'b100: begin
                assert (cyc - last_act[sd_ba] >= 2 && sd_a[10]) else $fatal(1, "tRCD/AP");
                if (!sd_we_n) assert (!model.dq_e) else $fatal(1, "DQ contention");
                // AP: tRAS (3) from ACT, then tRP 2; write adds tRDL 2.
                busy_until[sd_ba] = (sd_we_n ? cyc + 1 : cyc + 2) + 2;
                if (busy_until[sd_ba] < last_act[sd_ba] + 5)
                    busy_until[sd_ba] = last_act[sd_ba] + 5;
            end
            3'b001: begin
                for (int b = 0; b < 4; b++)
                    assert (cyc >= busy_until[b]) else $fatal(1, "REF bank busy");
                assert (cyc - last_ref >= 5) else $fatal(1, "tRFC");
                if (initialized && last_ref > 0 && cyc - last_ref > max_gap)
                    max_gap = cyc - last_ref;
                if (enable && cpu_refresh) refs_quiet++;
                refs++; last_ref = cyc;
            end
            default: ;
        endcase
        if (initialized && last_ref > 0)
            assert (cyc - last_ref <= 8054) else $fatal(1, "refresh interval > 125 us");
    end
    always @(posedge service) assert (model.errors == 0 && !core_hold) else $fatal(1, "model/hold");

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
            2: assert (rom_q == want) else $fatal(1, "ROM q %h want %h", rom_q, want);
            3: assert (save_q == want) else $fatal(1, "save q %h want %h", save_q, want);
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
            expect_by_edge4(2, 8'h11 * 8'(l + 1));
            rom_rd = 0; repeat (2) edge_();
        end
        // WRAM read, save read.
        edge_(); wram_addr = 17'h20; wram_rd = 1; expect_by_edge4(0, 8'h5a); wram_rd = 0;
        edge_(); save_addr = 17'h30; save_rd = 1; expect_by_edge4(3, 8'hc3); save_rd = 0;
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
            expect_by_edge4(2, 8'h11 * 8'(i % 4 + 1));
            rom_rd = 0; wram_wr = 0; repeat (4) edge_();
        end
        enable = 0;
        while (!drained) tick();
        host(0, 21'h100021, 32'ha6a6a6a6);
        for (int i = 0; i < 16; i++) host(0, 21'h100100 + 21'(i), {4{8'(i * 7 + 1)}});
        $display("PASS posted write forward, DMA read+write pairs, commits verified by host");
        // Fastest CPU stream: a new ROM read every 6 masters while refresh is due.
        enable = 1;
        for (int i = 0; i < 3000; i++) begin
            edge_(); rom_addr = 22'h40 + 22'(i % 4); rom_rd = 1;
            cpu_refresh = (i % 40) >= 34;           // quiet window like the S-CPU pause
            if (!cpu_refresh) begin
                repeat (4) edge_();
                assert (rom_q == 8'h11 * 8'(i % 4 + 1)) else $fatal(1, "stream read %0d", i);
                rom_rd = 0; edge_();
            end else begin rom_rd = 0; edge_(); end
        end
        cpu_refresh = 0;
        assert (deadline_fault == 0 && overrun_fault == 0 && !protocol_fault)
            else $fatal(1, "faults d=%b o=%b p=%b", deadline_fault, overrun_fault, protocol_fault);
        assert (refs_quiet > 0 && max_gap <= 8054) else $fatal(1, "refresh window");
        $display("PASS 6-master ROM stream, refresh in quiet windows (%0d), max gap %0d clocks",
                 refs_quiet, max_gap);
        // No quiet window at all: debt fallback keeps refresh within 125 us.
        for (int i = 0; i < 6000; i++) begin
            edge_(); rom_addr = 22'h40 + 22'(i % 4); rom_rd = 1;
            repeat (5) edge_(); rom_rd = 0;
        end
        assert (max_gap <= 8054) else $fatal(1, "refresh starved without quiet window");
        $display("PASS refresh fallback without quiet window, max gap %0d clocks (deadline=%b)",
                 max_gap, deadline_fault);
        // Overrun: a different read before the previous one completed is reported.
        edge_(); rom_addr = 22'h41; rom_rd = 1;
        edge_(); rom_addr = 22'h80;
        repeat (3) edge_(); rom_rd = 0;
        assert (overrun_fault[2]) else $fatal(1, "overrun not reported");
        $display("PASS overrun reported");
        $display("PASS snes_memory 3:1, no clock holds");
        $finish;
    end
    initial begin #400ms; $fatal(1, "timeout"); end
endmodule
`default_nettype wire
