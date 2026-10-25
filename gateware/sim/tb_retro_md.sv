// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
`timescale 1ns / 1ps

// Real FX68K/T80/VDP/JT12/JT89, not a gamecore stub. Synthetic program is
// self-authored in retro_md_program.svh. No console BIOS/game assets needed.
// Run from a directory containing the retained FX68K microrom.mem/nanorom.mem.
// Tool options retain the EXISTING upstream FX68K exceptions:
// -Wno-BLKANDNBLK: unpacked structs mix registered and combinational fields;
// --no-assert-case: implicit unique-case checks fire before startup reset.
// Explicit assertions here remain enabled with --assert. Upstream warnings
// remain visible (-Wno-fatal); do not suppress new testbench/adapter warnings.
// This is not game compatibility, DMA-deadline, CDC, board timing or STA proof.
module tb_retro_md;
  logic clk = 0, clk_z80 = 0, rst = 1, core_reset = 1, loading = 0;
  always #9.312 clk = ~clk;
  always @(negedge clk) clk_z80 <= ~clk_z80;
  wire sd_clk;
  assign #2 sd_clk = clk;  // simulation phase only, NOT board calibration
  wire [23:0] core_addr, debug_cpu, debug_vbus;
  wire [15:0] core_wdata, core_rdata;
  wire [1:0] core_be, resolution;
  wire core_we, core_req, core_ack, adapter_idle, fault;
  wire [3:0] red, green, blue;
  wire pixel_ce, hs, vs, hde, vde, field, interlace;
  wire signed [15:0] audio_l, audio_r;
  int cycles = 0;
  retro_md_core core (
      .clk_master_i(clk), .clk_z80_i(clk_z80), .reset_i(core_reset), .loading_i(loading),
      .pad1_i(12'(cycles >> 13)), .pad2_i(12'(cycles >> 12)), .rom_words_i(24'h001000),
      .mem_addr_o(core_addr), .mem_wdata_o(core_wdata), .mem_be_o(core_be),
      .mem_we_o(core_we), .mem_req_o(core_req), .mem_ack_i(core_ack), .mem_rdata_i(core_rdata),
      .red_o(red), .green_o(green), .blue_o(blue), .pixel_ce_o(pixel_ce),
      .hs_n_o(hs), .vs_n_o(vs), .hde_o(hde), .vde_o(vde),
      .interlace_o(interlace), .field_o(field), .resolution_o(resolution),
      .audio_left_o(audio_l), .audio_right_o(audio_r),
      .debug_m68k_addr_o(debug_cpu), .debug_vbus_addr_o(debug_vbus));
  wire req_valid, req_ready, req_write, rsp_valid, rsp_ready;
  wire [20:0] req_addr;
  wire [31:0] req_wdata, rsp_rdata;
  wire [3:0] req_mask;
  retro_md_memory adapter (
      .clk(clk), .rst(core_reset), .enable(!core_reset), .idle(adapter_idle), .fault(fault),
      .mem_req(core_req), .mem_ack(core_ack), .mem_addr(core_addr), .mem_we(core_we),
      .mem_be(core_be), .mem_wdata(core_wdata), .mem_rdata(core_rdata),
      .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_addr(req_addr),
      .req_wdata(req_wdata), .req_mask(req_mask), .rsp_valid(rsp_valid),
      .rsp_ready(rsp_ready), .rsp_rdata(rsp_rdata));
  wire mem_valid, mem_ready, mem_write, mem_rsp_valid, mem_rsp_ready;
  wire [20:0] mem_addr;
  wire [31:0] mem_wdata, mem_rdata;
  retro_mem_lanes lanes (.*);
  wire initialized, sd_ras_n, sd_cas_n, sd_we_n;
  wire [10:0] sd_a;
  wire [1:0] sd_ba;
  wire [31:0] sd_dq;
  wire [31:0] sd_dq_in, sd_dq_out;
  wire sd_dq_oe;
  retro_sdram_io io (.dq_in(sd_dq_in), .dq_out(sd_dq_out), .dq_oe(sd_dq_oe), .sd_dq(sd_dq));
  // ceil(ns / 18.624ns): RCD/RP=15ns, RFC=60ns, RAS=42ns,
  // WR=12ns, MRD=2 clocks, CAS=3. Init >=200us, nominal refresh <=7us.
  retro_sdram #(.InitCycles(10740), .RefreshCycles(375), .Trcd(1), .Trp(1),
      .Trfc(4), .Tras(3), .Twr(1), .Tmrd(2), .Cas(3)) controller (
      .clk(clk), .rst(rst), .initialized(initialized), .req_valid(mem_valid),
      .req_ready(mem_ready), .req_write(mem_write), .req_addr(mem_addr), .req_wdata(mem_wdata),
      .rsp_valid(mem_rsp_valid), .rsp_ready(mem_rsp_ready), .rsp_rdata(mem_rdata),
      .sd_a(sd_a), .sd_ba(sd_ba), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
      .sd_we_n(sd_we_n), .sd_dq_in(sd_dq_in), .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe));
  sdram_model #(.TAc(5.4ns)) model (
      .clk(sd_clk), .cke(1'b1), .cs_n(1'b0), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
      .we_n(sd_we_n), .ba(sd_ba), .a(sd_a), .dqm(4'b0000), .dq(sd_dq));

  int pixels = 0, red_pixels = 0, hs_edges = 0, audio_changes = 0, refreshes = 0;
  int transactions = 0, start_cycle = 0, min_read = 10000, max_read = 0;
  int min_write = 10000, max_write = 0;
  bit tracking = 0, pending_toggle = 0, pending_write = 0, old_hs = 0;
  logic [15:0] old_audio = 0;
  logic [23:0] pending_addr;
  logic [15:0] pending_data;
  logic [1:0] pending_be;
  always @(posedge clk) begin
    cycles++;
    if (!core_reset) begin
      assert (!fault) else $fatal(1, "adapter fault at CPU %h mem %h", debug_cpu, core_addr);
      if (!tracking && core_req != core_ack) begin
        tracking = 1;
        pending_toggle = core_req;
        pending_write = core_we;
        pending_addr = core_addr;
        pending_data = core_wdata;
        pending_be = core_be;
        start_cycle = cycles;
      end else if (tracking) begin
        if (core_ack == pending_toggle) begin
          if (pending_write) begin
            if (cycles-start_cycle < min_write) min_write = cycles-start_cycle;
            if (cycles-start_cycle > max_write) max_write = cycles-start_cycle;
          end else begin
            if (cycles-start_cycle < min_read) min_read = cycles-start_cycle;
            if (cycles-start_cycle > max_read) max_read = cycles-start_cycle;
          end
          transactions++;
          tracking = 0;
        end else begin
          assert (core_req == pending_toggle && core_addr == pending_addr &&
                  core_we == pending_write && core_wdata == pending_data && core_be == pending_be)
              else $fatal(1, "core changed outstanding request");
        end
      end
      if (hs != old_hs) hs_edges++;
      old_hs = hs;
      if (audio_l != old_audio) audio_changes++;
      old_audio = audio_l;
      if (pixel_ce && hde && vde) begin
        pixels++;
        if (red != 0 && green == 0 && blue == 0) red_pixels++;
      end
    end
  end
  int sd_cycle = 0, last_ref = -1000, max_refresh_gap = 0;
  int last_act [4] = '{-1000, -1000, -1000, -1000};
  int last_pre [4] = '{-1000, -1000, -1000, -1000};
  int last_write [4] = '{-1000, -1000, -1000, -1000};
  always @(posedge sd_clk) begin
    sd_cycle++;
    case ({sd_ras_n, sd_cas_n, sd_we_n})
      3'b011: begin
        assert (sd_cycle-last_pre[sd_ba] >= 1 && sd_cycle-last_ref >= 4)
            else $fatal(1, "ACT violates tRP/tRFC");
        last_act[sd_ba] = sd_cycle;
      end
      3'b100: last_write[sd_ba] = sd_cycle;
      3'b010: begin
        for (int i = 0; i < 4; i++) if (sd_a[10] || 2'(i) == sd_ba) begin
          assert (sd_cycle-last_act[i] >= 3 && sd_cycle-last_write[i] >= 1)
              else $fatal(1, "PRE violates tRAS/tWR");
          last_pre[i] = sd_cycle;
        end
      end
      3'b001: begin
        for (int i = 0; i < 4; i++)
          assert (sd_cycle-last_pre[i] >= 1) else $fatal(1, "REF violates tRP");
        assert (sd_cycle-last_ref >= 4) else $fatal(1, "REF violates tRFC");
        if (initialized && sd_cycle-last_ref > max_refresh_gap)
          max_refresh_gap = sd_cycle-last_ref;
        last_ref = sd_cycle;
        refreshes++;
      end
      3'b000: assert (sd_cycle >= 10740) else $fatal(1, "MRS before 200us init");
      default: ;
    endcase
    if (initialized)
      assert (sd_cycle-last_ref < 419) else $fatal(1, "refresh gap >=7.8us");
  end

  function automatic logic [15:0] word_at(input int offset);
    logic [31:0] word32;
    logic [15:0] halfword;
    word32 = model.mem[21'h100000 + 21'(offset/4)];
    halfword = offset[1] ? word32[31:16] : word32[15:0];
    return {halfword[7:0], halfword[15:8]};
  endfunction

`include "retro_md_program.svh"

  initial begin
    init_program();
    repeat (8) @(negedge clk);
    rst = 0;
    repeat (56) @(negedge clk);
    loading = 1;
    repeat (16384) @(negedge clk);
    assert (initialized) else $fatal(1, "SDRAM initialization incomplete");
    loading = 0;
    core_reset = 0;
    repeat (950000) @(negedge clk);
    $display("MD physical: WRAM=%h copy=%h region=%h Z80=%h VRAM=%h,%h",
             word_at(0), word_at(2), word_at(4), word_at(6), word_at(8), word_at(10));
    $display("transactions=%0d read_latency=%0d..%0d write_latency=%0d..%0d MCLK",
             transactions, min_read, max_read, min_write, max_write);
    $display("pixels=%0d red=%0d hs_edges=%0d audio_changes=%0d refresh=%0d model_errors=%0d",
             pixels, red_pixels, hs_edges, audio_changes, refreshes, model.errors);
    $display("max_refresh_gap=%0d MCLK (18.624ns)", max_refresh_gap);
    assert (word_at(0) == 16'hABCD && word_at(2) == 16'hABCD && word_at(4) == 16'hA0A0 &&
            word_at(6) == 16'h5A5A && word_at(8) == 16'h1357 && word_at(10) == 16'h2468)
        else $fatal(1, "real MD synthetic readback failure");
    assert (pixels > 0 && red_pixels > 0 && hs_edges > 10 && audio_changes > 0 &&
            refreshes > 100 && model.errors == 0 && transactions > 100)
        else $fatal(1, "real MD activity/model failure");
    $finish;
  end
  initial begin
    #25ms;
    $fatal(1, "timeout");
  end
endmodule
