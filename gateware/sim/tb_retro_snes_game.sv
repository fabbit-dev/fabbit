// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
`timescale 1ns / 1ps
// SNES at full speed: retro_snes_clocks (3:1) -> snes_system -> pad-register DQ
// (behavioural ODDR/IDDR) -> SDRAM model with board delays. Reference = the same
// core with ideal memory (per-frame pixel/audio hashes, "F n fh ah px unsup" lines).
// No ROM or SPC asset is bundled: the user supplies them as hex, one byte (IPL,
// ROM) or one 12-bit value (gauss) per line: +rom= +rom_bytes= +ipl= +gauss=,
// optional +hirom=1 +frames=N +start=F (Start held 3 frames) +ref=<file>.
// Board, chip and SDRAM protocol monitor: retro_sdram_board.
// Checks: SDRAM protocol, refresh interval, no deadline miss, no overrun,
// frame-exact video/audio against the reference, master edges per frame = free.
module tb_retro_snes_game;
    parameter realtime SdDelay = 0.5ns;   // board flight of the forwarded clock
    parameter realtime DqInDelay = 5ns;   // board + input buffer + 2 ns IDELAY
    logic source = 0;
    always #23.28ns source = !source;
    wire service, master, memory_clock, locked, master_ce;
    retro_snes_clocks clocks (.clk_source(source), .reset(1'b0), .service, .master,
        .memory_clock, .idelay_ref(), .locked, .master_ce);

    logic reset = 1, run = 0, memory_reset = 0;
    logic [1:0] cfg_map = 0;
    logic [21:0] cfg_rom_mask = 22'h07ffff;
    logic cfg_save_enable = 1;
    logic [16:0] cfg_save_mask = 17'h007ff;
    logic [11:0] pad1;
    logic asset_start = 0, asset_valid = 0, asset_last = 0;
    logic [1:0] asset_channel = 0;
    logic [10:0] asset_addr = 0;
    logic [7:0] asset_data = 0;
    wire asset_ready, asset_busy, asset_done;
    wire [2:0] asset_error;
    wire ipl_ready, coeff_ready, active, stop_ack;
    wire [4:0] unsupported;
    wire memory_initialized, memory_drained, memory_hold, refresh_busy, refresh_forced;
    wire [3:0] request_inflight, max_latency;
    wire [2:0] needs_data, deadline_fault, overrun_fault;
    wire protocol_fault, clock_permit, core_step, clk_core;
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
    wire [14:0] rgb;
    wire pixel_ce, dotclk, hs, vs, hde, vde, highres, field, interlace, v224;
    wire [8:0] x, y;
    wire signed [15:0] audio_l, audio_r;
    wire audio_ready;
    snes_system dut (
        .clk_service(service), .free_master(master), .free_master_ce(master_ce),
        .reset, .console_reset(1'b0), .run, .memory_reset, .cfg_map, .cfg_chip(8'd0),
        .cfg_pal(1'b0), .cfg_rom_mask, .cfg_save_enable, .cfg_save_mask, .pad1,
        .pad2(12'd0), .asset_start, .asset_channel, .asset_valid, .asset_ready,
        .asset_addr, .asset_data, .asset_last, .asset_busy, .asset_done, .asset_error,
        .ipl_ready, .coeff_ready, .active, .stop_ack, .unsupported,
        .memory_initialized, .memory_drained, .memory_hold, .refresh_busy, .refresh_forced,
        .request_inflight, .needs_data, .deadline_fault, .overrun_fault, .protocol_fault,
        .clock_permit, .core_step, .clk_core, .host_valid, .host_write, .host_addr,
        .host_wdata, .host_ready, .host_done, .host_rdata, .sd_a, .sd_ba, .sd_ras_n,
        .sd_cas_n, .sd_we_n, .sd_cs_n, .sd_cke, .sd_dq_in, .sd_dq_out, .sd_dq_oe_next,
        .sd_dq_oe, .max_latency, .rgb, .pixel_ce, .dotclk, .hs, .vs, .hde, .vde, .highres,
        .field, .interlace, .v224, .x, .y, .audio_l, .audio_r, .audio_ready);

    wire sd_clk;
    tri [31:0] chip_dq;
    retro_sdram_board #(.SdDelay(SdDelay), .DqInDelay(DqInDelay)) board (
        .clk_service(service), .memory_clock, .initialized(memory_initialized),
        .sd_a, .sd_ba, .sd_ras_n, .sd_cas_n, .sd_we_n, .sd_cs_n, .sd_cke, .sd_dq_out,
        .sd_dq_oe_next, .sd_dq_in, .sd_clk, .chip_dq);

    // Frame hashes, same as the ideal-memory reference bench.
    logic [31:0] fh = 32'h811c9dc5, ah = 32'h811c9dc5;
    logic vs_d = 0;
    int frame = 0, frames, pixels = 0, master_edges = 0, core_edges = 0, mism = 0;
    int ref_fh [1024], ref_ah [1024], ref_n = 0;
    longint last_vs_master = 0;
    always @(posedge service) begin
        if (master_ce && run) master_edges++;
        if (core_step && run) core_edges++;
    end
    always @(posedge clk_core) begin
        if (pixel_ce) begin fh <= (fh ^ {17'd0, rgb}) * 32'h01000193; pixels <= pixels + 1; end
        if (audio_ready) ah <= (ah ^ {audio_l, audio_r}) * 32'h01000193;
        vs_d <= vs;
        if (vs && !vs_d) begin
            bit bad = frame < ref_n && (ref_fh[frame] != fh || ref_ah[frame] != ah);
            $display("F %0d fh %08x ah %08x px %0d edges %0d lat %0d%s", frame, fh, ah, pixels,
                     master_edges - last_vs_master, max_latency, bad ? " MISMATCH" : "");
            if (bad) mism++;
            last_vs_master = master_edges;
            fh <= 32'h811c9dc5; pixels <= 0; frame <= frame + 1;
            if (frame + 1 >= frames) finish();
        end
    end
    always @(posedge service) if (run && active)
        assert (overrun_fault == 0 && !protocol_fault && (deadline_fault == 0 || nodl) &&
                !refresh_forced &&
                !memory_hold)
            else $fatal(1, "memory fault o=%b p=%b d=%b", overrun_fault,
                        protocol_fault, deadline_fault);

    int startf, nodl;
    always @(posedge master) pad1 <= (frame >= startf && frame < startf + 3) ? 12'h008 : 12'h000;
    task automatic finish;
        $display("frames %0d mismatches %0d max_latency %0d max_ref_gap %0d refreshes %0d",
                 frame + 1, mism, max_latency, board.max_ref_gap, board.refreshes);
        $display("max refresh burst %0d, refreshes needed %0d", board.max_burst,
                 board.refreshes_needed());
        $display("master edges %0d core edges %0d stalls %0d", master_edges, core_edges,
                 master_edges - core_edges);
        // Burst and interval limits are asserted by the board monitor; here the average:
        // 4096 per 64 ms (one per 1006 clocks).
        assert (mism == 0 && ref_n >= frame + 1 && master_edges == core_edges &&
                board.refresh_rate_ok())
            else $fatal(1, "FAIL");
        $display("PASS full-speed SNES game run, no clock holds");
        $finish;
    endtask

    task automatic tick; @(posedge service); #1ns; endtask
    task automatic master_tick; @(posedge master); #1ns; endtask
    logic [7:0] rom [4194304];
    logic [7:0] ipl [64];
    logic [11:0] gauss [512];
    task automatic load_asset(input int ch);
        asset_channel = 2'(ch); asset_start = 1; master_tick(); asset_start = 0;
        master_tick();
        for (int i = 0; i < (ch == 0 ? 64 : 1024); i++) begin
            while (!asset_ready) master_tick();
            asset_valid = 1; asset_addr = 11'(i);
            asset_data = ch == 0 ? ipl[i] : i[0] ? 8'(gauss[i>>1] >> 8) : gauss[i>>1][7:0];
            asset_last = i == (ch == 0 ? 63 : 1023);
            master_tick(); asset_valid = 0;
        end
        do master_tick(); while (asset_busy);
        assert (asset_done && asset_error == 0) else $fatal(1, "asset load");
        master_tick();
    endtask
    task automatic host_request(input bit wr, input int addr, input logic [31:0] value);
        while (!host_ready) tick();
        @(negedge service);
        host_addr = 21'(addr); host_write = wr; host_wdata = value; host_valid = 1;
        tick(); host_valid = 0;
        do tick(); while (!host_done);
        if (!wr) assert (host_rdata == value)
            else $fatal(1, "host readback %h got %h want %h", addr, host_rdata, value);
    endtask
    initial begin
        string rf, reff, ipf, gaf;
        int rom_bytes, hirom, fd, n, f, h1, h2;
        if (!$value$plusargs("rom=%s", rf) || !$value$plusargs("ipl=%s", ipf) ||
            !$value$plusargs("gauss=%s", gaf)) $fatal(1, "need +rom= +ipl= +gauss=");
        if (!$value$plusargs("rom_bytes=%d", rom_bytes)) rom_bytes = 524288;
        if (!$value$plusargs("hirom=%d", hirom)) hirom = 0;
        if (!$value$plusargs("frames=%d", frames)) frames = 60;
        if (!$value$plusargs("start=%d", startf)) startf = 100000;
        if (!$value$plusargs("nodl=%d", nodl)) nodl = 0;
        if ($value$plusargs("ref=%s", reff)) begin
            fd = $fopen(reff, "r");
            while ($fscanf(fd, "F %d fh %h ah %h px %d unsup %b\n", f, h1, h2, n, n) == 5) begin
                ref_fh[f] = h1; ref_ah[f] = h2; ref_n = f + 1;
            end
            $fclose(fd);
            $display("reference frames %0d", ref_n);
        end
        cfg_map = 2'(hirom);
        cfg_rom_mask = 22'(rom_bytes - 1);
        $readmemh(rf, rom);
        $readmemh(ipf, ipl);
        $readmemh(gaf, gauss);
        while (!locked) #10ns;
        repeat (8) master_tick();
        reset = 0;
        while (dut.stop_state != 0 || asset_busy) master_tick();
        repeat (2) master_tick();
        $display("[%0t] stopped, loading assets", $time);
        load_asset(0); load_asset(1);
        $display("[%0t] assets ok", $time);
        while (!stop_ack) tick();
        $display("[%0t] stop_ack, host load", $time);
        // ROM through the real host path for the first 1 KiB, the rest preloaded.
        for (int i = 0; i < 256; i++)
            host_request(1, i, {rom[4*i+3], rom[4*i+2], rom[4*i+1], rom[4*i]});
        for (int i = 0; i < 256; i += 37)
            host_request(0, i, {rom[4*i+3], rom[4*i+2], rom[4*i+1], rom[4*i]});
        for (int i = 256; i < rom_bytes / 4; i++)
            board.model.mem[21'(i)] = {rom[4*i+3], rom[4*i+2], rom[4*i+1], rom[4*i]};
        // WRAM/ARAM zero, save FF, as in the reference.
        for (int i = 0; i < 131072; i++) board.model.mem[21'h100000 + 21'(i)] = 0;
        for (int i = 0; i < 2048; i++) board.model.mem[21'h120000 + 21'(i)] = 32'hffffffff;
        for (int i = 0; i < 65536; i++) dut.aram.ram[i] = 0;
        while (!memory_drained) tick();
        $display("[%0t] run", $time);
        run = 1;
    end
    initial begin #20s; $fatal(1, "timeout"); end
endmodule
`default_nettype wire
