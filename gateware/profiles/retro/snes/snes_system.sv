// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// Complete clock-stretched SNES -> SDRAM constituent for a static bitstream.
// No PLL/physical pins/HDMI. Related service/master clocks externally provided.
// Asset stream/pads/config synchronous to free_master; stop requests run/
// console_reset, reset, host stream and refresh_now synchronous to clk_service
// (related free-master launches also allowed). Stable config until stop_ack.
// Assets loader uses free_master; console asset backend uses clk_core. These
// clocks are identical while stopped/programming; run MUST remain zero until
// loader done/busy clear. Memory is continuously clocked at 4x, even on hold.
// *_valid A/V strobes are qualified by actual core_step in SERVICE domain;
// held raw core pulses are never re-counted while the clock is stopped.
// Reset clears validity and restarts SDRAM; reload all synthetic/user assets.
// Assert reset for >=4 free-master periods so the gated synchronous domain
// receives reset edges regardless of a preceding memory hold/startup CE state.
// Console reset is registered on ungated master; assertion can take one period.
// Service reset still discards memory work immediately on its sampling edge.
// run is a REQUEST, not immediate core reset. run=0 quiesces actual core clock,
// preserves last-edge +1-service sampling, drains accepted operations, then
// resets console and asserts stop_ack. Only after stop_ack may config/assets/
// physical SDRAM ownership change. Global reset intentionally discards queued
// requests (already issued physical writes cannot be undone); reload afterwards.
// memory_reset is a SEPARATE stopped-only reinitialization of the physical memory
// protocol. It never invalidates IPL/coefficient coverage. Host/run stay blocked
// until memory initialization and the stop acknowledgement become true again.
module snes_system #(
    parameter int unsigned InitCycles = 18000,
    parameter int unsigned RefreshCycles = 480
) (
    input wire clk_service, free_master, free_master_ce,
    input wire reset, console_reset, run,
    // Assert only after stop_ack and accepted host work drained. Reinitializes
    // physical SDRAM on owner handover WITHOUT clearing runtime asset coverage.
    input wire memory_reset,
    input wire [1:0] cfg_map,
    input wire [7:0] cfg_chip,
    input wire cfg_pal,
    input wire [21:0] cfg_rom_mask,
    input wire cfg_save_enable,
    input wire [16:0] cfg_save_mask,
    input wire [11:0] pad1, pad2,
    input wire asset_start,
    input wire [1:0] asset_channel,
    input wire asset_valid,
    output wire asset_ready,
    input wire [10:0] asset_addr,
    input wire [7:0] asset_data,
    input wire asset_last,
    output wire asset_busy, asset_done,
    output wire [2:0] asset_error,
    output wire ipl_ready, coeff_ready,
    output wire active,
    output wire stop_ack,
    output wire [4:0] unsupported,
    input wire refresh_now,
    output wire memory_initialized, memory_drained, memory_hold, refresh_busy,
    output wire [4:0] request_inflight,
    output wire [3:0] needs_data, deadline_fault, overrun_fault,
    output wire protocol_fault,
    output wire clock_permit, core_step, clk_core,
    input wire host_valid, host_write,
    input wire [20:0] host_addr,
    input wire [31:0] host_wdata,
    output wire host_ready, host_done,
    output wire [31:0] host_rdata,
    output wire [10:0] sd_a,
    output wire [1:0] sd_ba,
    output wire sd_ras_n, sd_cas_n, sd_we_n, sd_cs_n, sd_cke,
    input wire [31:0] sd_dq_in,
    output wire [31:0] sd_dq_out,
    output wire sd_dq_oe,
    output wire [14:0] rgb,
    output wire pixel_ce, dotclk, hs, vs, hde, vde,
    output wire highres, field, interlace, v224,
    output wire [8:0] x, y,
    output wire signed [15:0] audio_l, audio_r,
    output wire audio_ready
);
    wire ipl_clear, ipl_we, coeff_clear, coeff_we;
    wire [5:0] ipl_addr;
    wire [7:0] ipl_data;
    wire [8:0] coeff_addr;
    wire [11:0] coeff_data;
    wire [16:0] wram_addr, save_addr;
    wire [15:0] aram_addr;
    wire [21:0] rom_addr;
    wire [7:0] wram_data, aram_data, save_data;
    wire [7:0] wram_q, aram_q, rom_q, save_q;
    wire wram_rd, wram_wr, aram_rd, aram_wr, rom_rd, save_rd, save_wr;
    wire raw_pixel_ce, raw_audio_ready;
    typedef enum logic [1:0] {Stopped, Running, Draining, Resetting} stop_state_t;
    stop_state_t stop_state;
    logic [1:0] sample_age, reset_edges;
    wire stop_requested = !run || console_reset || asset_error != 0 || asset_start;
    wire execution_requested = stop_state == Running || stop_state == Draining;
    logic console_run;
    // Keep service reset out of the live console ENABLE/reset/datapath cone.
    // Ungated master runs during holds; initialize asserted for fail-closed startup.
    logic console_reset_master = 1'b1;
    // The service FSM must not release CPU reset/ENABLE one service period
    // before an execution edge. Launch run on the UNGATED master instead: that
    // edge still resets the console, leaving a full master period to settle.
    // This register also clears while the execution clock is stopped.
    always_ff @(posedge free_master) begin
        console_reset_master <= reset;
        if (reset || console_reset_master) console_run <= 0;
        else console_run <= execution_requested;
    end
    // Retain run through the last-edge sampling aperture and physical drain.
    // After drain keep the guard closed until the ungated register clears;
    // otherwise reopening reset clocks could execute one stale-running edge.
    wire guard_hold = memory_hold || (console_run &&
                      (stop_requested || stop_state != Running));
    wire loader_locked = run || stop_state != Stopped;
    wire host_ready_internal;
    assign stop_ack = !reset && !run && stop_state == Stopped && memory_drained;
    assign host_ready = stop_ack && host_ready_internal;
    assign pixel_ce = core_step && raw_pixel_ce && active;
    assign audio_ready = core_step && raw_audio_ready && active;

    always_ff @(posedge clk_service) begin
        if (reset) begin
            stop_state <= Resetting;
            sample_age <= 0;
            reset_edges <= 0;
        end else begin
            // Include the sampling aperture AFTER the last real console edge.
            // Requiring permit=0 also covers a previously armed BUFGCE edge
            // when run falls during free-master low half.
            if (core_step) sample_age <= 0;
            else if (sample_age != 3) sample_age <= sample_age + 1'b1;
            case (stop_state)
                Stopped: if (run && !console_reset && memory_initialized && memory_drained &&
                             !asset_start && !asset_busy && asset_error == 0 &&
                             ipl_ready && coeff_ready) stop_state <= Running;
                Running: if (stop_requested) stop_state <= Draining;
                Draining: if (!clock_permit && sample_age >= 2 && memory_drained) begin
                    stop_state <= Resetting;
                    reset_edges <= 0;
                end
                Resetting: if (core_step) begin
                    if (reset_edges == 3) stop_state <= Stopped;
                    else reset_edges <= reset_edges + 1'b1;
                end
                default: stop_state <= Resetting;
            endcase
        end
    end

    snes_asset_loader loader (
        .clk(free_master), .reset, .run(loader_locked),
        .start(asset_start), .channel(asset_channel), .byte_valid(asset_valid),
        .byte_ready(asset_ready), .byte_addr(asset_addr), .byte_data(asset_data),
        .byte_last(asset_last), .backend_ipl_ready(ipl_ready),
        .backend_coeff_ready(coeff_ready), .busy(asset_busy), .done(asset_done),
        .error(asset_error), .ipl_clear, .ipl_we, .ipl_addr, .ipl_data,
        .coeff_clear, .coeff_we, .coeff_addr, .coeff_data
    );
    snes_clock_guard guard (
        .clk_service, .free_master, .free_master_ce, .reset,
        .running(console_run), .core_hold(guard_hold),
        .permit(clock_permit), .core_step, .clk_core
    );
    snes_console console (
        .clk(clk_core), .reset(console_reset_master), .console_reset(1'b0), .run(console_run),
        .cfg_map, .cfg_chip, .cfg_pal, .cfg_rom_mask, .cfg_save_enable, .cfg_save_mask,
        .pad1, .pad2, .ipl_clear, .ipl_we, .ipl_addr, .ipl_data, .ipl_ready,
        .coeff_clear, .coeff_we, .coeff_addr, .coeff_data, .coeff_ready,
        .active, .unsupported, .wram_addr, .wram_data, .wram_rd, .wram_wr, .wram_q,
        .aram_addr, .aram_data, .aram_rd, .aram_wr, .aram_q,
        .rom_addr, .rom_rd, .rom_q, .save_addr, .save_data, .save_rd, .save_wr, .save_q,
        .sysclk_f_ce(), .sysclk_r_ce(), .refresh(), .rgb, .pixel_ce(raw_pixel_ce),
        .dotclk, .hs, .vs, .hde, .vde, .highres, .field, .interlace, .v224, .x, .y,
        .audio_l, .audio_r, .audio_ready(raw_audio_ready)
    );
    snes_memory #(.InitCycles(InitCycles), .RefreshCycles(RefreshCycles)) memory (
        .clk(clk_service), .reset(reset || memory_reset), .master_ce(core_step),
        .enable(active), .refresh_now,
        .initialized(memory_initialized), .drained(memory_drained),
        .core_hold(memory_hold), .request_inflight, .needs_data,
        .refresh_busy, .deadline_fault, .overrun_fault, .protocol_fault,
        .wram_addr, .wram_data, .wram_rd, .wram_wr, .wram_q,
        .wram_valid(), .wram_posted(), .wram_committed(),
        .aram_addr, .aram_data, .aram_rd, .aram_wr, .aram_q,
        .aram_valid(), .aram_posted(), .aram_committed(), .rom_addr, .rom_rd, .rom_q,
        .rom_valid(), .save_addr, .save_data, .save_rd, .save_wr, .save_q,
        .save_valid(), .save_posted(), .save_committed(),
        .host_valid(host_valid && stop_ack), .host_write, .host_addr, .host_wdata,
        .host_ready(host_ready_internal), .host_done, .host_rdata,
        .sd_a, .sd_ba, .sd_ras_n, .sd_cas_n, .sd_we_n, .sd_cs_n, .sd_cke,
        .sd_dq_in, .sd_dq_out, .sd_dq_oe
    );
endmodule
`default_nettype wire
