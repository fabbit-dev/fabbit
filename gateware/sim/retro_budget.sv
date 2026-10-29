// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none

// AREA_BUDGET_UNCONNECTED_MEMORY_RETURN_PORTS_NOT_FUNCTIONAL_PROFILE
// Never flash. All core memory returns remain independent runtime INPUTS;
// real adapters/controllers are counted but do NOT feed those core inputs.
// All essential core outputs and backend read/status outputs are observable.
// Includes ALL NES mappers, three real memory controllers, RGB333 shared
// framebuffer, pixel/stream FIFOs, loader/fabric, bus/ICAP, clocking and DVI.
// NOT included: audio transport/mixer, CSR decoder, SNES high-res decimator,
// memory CDC bridges, safe physical-controller handover, board constraints.
// mem_fast_clk is external: an additional SNES-memory PLL is NOT counted.
// Raw source resets/selection are NOT safe runtime handover implementation.
module retro_budget (
    input wire clk_25m, mem_fast_clk, reset,
    input wire [1:0] select,
    input wire [63:0] nes_flags,
    input wire [11:0] pad,
    input wire [7:0] nes_cpu_data, nes_ppu_data,
    output wire [21:0] nes_cpu_addr, nes_ppu_addr,
    output wire nes_cpu_rd, nes_cpu_wr, nes_ppu_rd, nes_ppu_wr,
    output wire [7:0] nes_cpu_wrdata, nes_ppu_wrdata,
    output wire [5:0] nes_color,
    output wire [2:0] nes_emphasis,
    output wire [8:0] nes_cycle, nes_line,
    output wire [15:0] nes_sample,
    input wire md_loading, md_ack,
    input wire [23:0] md_rom_words,
    input wire [15:0] md_rdata,
    output wire [23:0] md_addr,
    output wire [15:0] md_wdata,
    output wire [1:0] md_be,
    output wire md_we, md_req,
    output wire [3:0] md_red, md_green, md_blue,
    output wire md_pixel, md_hs, md_vs, md_hde, md_vde, md_interlace, md_field,
    output wire [1:0] md_resolution,
    output wire [15:0] md_left, md_right,
    input wire [1:0] snes_map,
    input wire [7:0] snes_chip,
    input wire snes_pal,
    input wire [21:0] snes_rom_mask,
    input wire snes_save_enable,
    input wire [16:0] snes_save_mask,
    input wire ipl_clear, ipl_we,
    input wire [5:0] ipl_addr,
    input wire [7:0] ipl_data,
    input wire coeff_clear, coeff_we,
    input wire [8:0] coeff_addr,
    input wire [11:0] coeff_data,
    output wire ipl_ready, coeff_ready, snes_active,
    output wire [4:0] snes_unsupported,
    output wire [16:0] wram_addr, save_addr,
    output wire [15:0] aram_addr,
    output wire [21:0] rom_addr,
    output wire [7:0] wram_data, aram_data, save_data,
    input wire [7:0] wram_q, aram_q, rom_q, save_q,
    output wire wram_rd, wram_wr, aram_rd, aram_wr, rom_rd, save_rd, save_wr,
    output wire sysclk_f_ce, sysclk_r_ce, refresh,
    output wire [14:0] snes_rgb,
    output wire snes_pixel, snes_dot, snes_hs, snes_vs, snes_hde, snes_vde,
    output wire snes_highres, snes_field, snes_interlace, snes_v224,
    output wire [8:0] snes_x, snes_y,
    output wire [15:0] snes_left, snes_right,
    output wire snes_audio_ready,
    input wire snes_master_ce, snes_memory_enable,
    output wire snmem_initialized, snmem_drained, snmem_core_hold,
    output wire [4:0] snmem_request_inflight,
    output wire [3:0] snmem_needs_data, snmem_deadline_fault, snmem_overrun_fault,
    output wire snmem_refresh_busy, snmem_protocol_fault,
    output wire [7:0] snmem_wram_q, snmem_aram_q, snmem_rom_q, snmem_save_q,
    output wire snmem_wram_valid, snmem_wram_posted, snmem_wram_committed,
    output wire snmem_aram_valid, snmem_aram_posted, snmem_aram_committed,
    output wire snmem_rom_valid, snmem_save_valid, snmem_save_posted, snmem_save_committed,
    input wire snmem_host_valid, snmem_host_write,
    input wire [20:0] snmem_host_addr,
    input wire [31:0] snmem_host_wdata,
    output wire snmem_host_ready, snmem_host_done,
    output wire [31:0] snmem_host_rdata,
    output wire [10:0] snmem_sd_a,
    output wire [1:0] snmem_sd_ba,
    output wire snmem_sd_ras_n, snmem_sd_cas_n, snmem_sd_we_n, snmem_sd_cs_n, snmem_sd_cke,
    input wire [31:0] snmem_sd_dq_in,
    output wire [31:0] snmem_sd_dq_out,
    output wire snmem_sd_dq_oe,
    input wire loader_begin, loader_abort, loader_commit,
    input wire [1:0] loader_system,
    input wire [23:0] loader_length,
    input wire loader_all_idle, loader_fifo_empty, loader_init_ready,
    input wire loader_backend_valid, loader_backend_fail,
    output wire loader_ready, loader_loading, loader_done, loader_failed, loader_flush,
    output wire [2:0] loader_run,
    output wire [1:0] loader_selected,
    output wire [23:0] loader_received,
    output wire loader_memory_idle,
    input wire [1:0] fabric_owner,
    output wire fabric_idle, md_adapter_idle, md_adapter_fault,
    input wire md_adapter_enable,
    output wire md_adapter_ack,
    output wire [15:0] md_adapter_rdata,
    input wire [31:0] generic_dq_in,
    output wire [31:0] generic_dq_out,
    output wire generic_dq_oe,
    output wire [10:0] generic_sd_a,
    output wire [1:0] generic_sd_ba,
    output wire generic_sd_ras_n, generic_sd_cas_n, generic_sd_we_n, generic_initialized,
    input wire esp_sck, esp_cs_n,
    inout wire [3:0] esp_d,
    output wire esp_irq, clk_bus, rst_bus, csr_we,
    output wire [7:0] csr_waddr, csr_raddr,
    output wire [31:0] csr_wdata,
    input wire [31:0] csr_rdata,
    output wire st_valid,
    output wire [7:0] st_chan, st_data,
    output wire [31:0] shell_pad,
    output wire shell_pad_stb, stream_ready,
    output wire [12:0] stream_level,
    input wire stream_wreset, stream_rreset,
    input wire video_clear, video_visible, video_wide, video_tall, nes_pixel_ce,
    output wire [2:0] pixel_fifo_ready,
    output wire [9:0] pixel_level [3],
    output wire md_video_overflow, snes_video_overflow,
    output wire [3:0] hdmi_p, hdmi_n, clock_locks,
    input wire nes_psen, nes_psincdec,
    output wire nes_psdone, nes_fclk, nes_sdram_clock,
    output wire nes_mem_busy, nes_clkref,
    output wire [7:0] nes_backend_cpu_data, nes_backend_ppu_data,
    input wire nes_clkref_sync,
    output wire [10:0] nes_sd_a,
    output wire [1:0] nes_sd_ba,
    output wire nes_sd_ras_n, nes_sd_cas_n, nes_sd_we_n, nes_sd_clk,
    inout wire [31:0] nes_sd_dq
);
  import video_pkg::*;
  import nes_palette_pkg::*;
  wire nes_clk, md_clk, z80_clk, snes_clk, clk_pix, clk_5x, rst_pix;
  retro_area cores (.*);
  snes_memory snes_backend (
      .clk(mem_fast_clk), .reset(reset), .master_ce(snes_master_ce),
      .enable(snes_memory_enable), .refresh_now(refresh), .initialized(snmem_initialized),
      .drained(snmem_drained), .core_hold(snmem_core_hold),
      .request_inflight(snmem_request_inflight), .needs_data(snmem_needs_data),
      .refresh_busy(snmem_refresh_busy), .deadline_fault(snmem_deadline_fault),
      .overrun_fault(snmem_overrun_fault), .protocol_fault(snmem_protocol_fault),
      .wram_addr(wram_addr), .wram_data(wram_data), .wram_rd(wram_rd), .wram_wr(wram_wr),
      .wram_q(snmem_wram_q), .wram_valid(snmem_wram_valid), .wram_posted(snmem_wram_posted),
      .wram_committed(snmem_wram_committed), .aram_addr(aram_addr), .aram_data(aram_data),
      .aram_rd(aram_rd), .aram_wr(aram_wr), .aram_q(snmem_aram_q), .aram_valid(snmem_aram_valid),
      .aram_posted(snmem_aram_posted), .aram_committed(snmem_aram_committed),
      .rom_addr(rom_addr), .rom_rd(rom_rd), .rom_q(snmem_rom_q), .rom_valid(snmem_rom_valid),
      .save_addr(save_addr), .save_data(save_data), .save_rd(save_rd), .save_wr(save_wr),
      .save_q(snmem_save_q), .save_valid(snmem_save_valid), .save_posted(snmem_save_posted),
      .save_committed(snmem_save_committed), .host_valid(snmem_host_valid),
      .host_write(snmem_host_write), .host_addr(snmem_host_addr), .host_wdata(snmem_host_wdata),
      .host_ready(snmem_host_ready), .host_done(snmem_host_done), .host_rdata(snmem_host_rdata),
      .sd_a(snmem_sd_a), .sd_ba(snmem_sd_ba), .sd_ras_n(snmem_sd_ras_n),
      .sd_cas_n(snmem_sd_cas_n), .sd_we_n(snmem_sd_we_n), .sd_cs_n(snmem_sd_cs_n),
      .sd_cke(snmem_sd_cke), .sd_dq_in(snmem_sd_dq_in),
      .sd_dq_out(snmem_sd_dq_out), .sd_dq_oe(snmem_sd_dq_oe));

  retro_clocks console_clocks (.clk_25m(clk_25m), .reset(reset), .clk_md(md_clk),
      .clk_z80(z80_clk), .clk_snes(snes_clk), .locked(clock_locks[0]));
  nes_clocks nes_clocking (.clk_25m(clk_25m), .psclk(clk_bus), .psen(nes_psen),
      .psincdec(nes_psincdec), .psdone(nes_psdone), .clk(nes_clk), .fclk(nes_fclk),
      .sdram_clk(nes_sdram_clock), .locked(clock_locks[1]));
  video_clocks video_clocking (.clk_25m(clk_25m), .clk_pix(clk_pix), .clk_5x(clk_5x),
      .locked(clock_locks[2]), .rst_pix(rst_pix));
  assign clock_locks[3] = !rst_bus;
  profile_bus #(.ProfileId(16'h0004), .UseIcap(1'b1)) bus (
      .clk_25m(clk_25m), .esp_sck(esp_sck), .esp_cs_n(esp_cs_n), .esp_d(esp_d),
      .esp_irq(esp_irq), .clk_bus(clk_bus), .rst_bus(rst_bus), .csr_we(csr_we),
      .csr_waddr(csr_waddr), .csr_wdata(csr_wdata), .csr_raddr(csr_raddr),
      .csr_rdata(csr_rdata), .st_valid(st_valid), .st_chan(st_chan), .st_data(st_data),
      .pad(shell_pad), .pad_stb(shell_pad_stb));
  nes_sdram nes_backend (.clk(nes_clk), .fclk(nes_fclk), .sdram_clk(nes_sdram_clock),
      .rst(reset), .clkref_sync(nes_clkref_sync), .clkref(nes_clkref), .busy(nes_mem_busy),
      .addr_a(nes_cpu_addr), .oe_a(nes_cpu_rd), .we_a(nes_cpu_wr), .din_a(nes_cpu_wrdata),
      .dout_a(nes_backend_cpu_data), .addr_b(nes_ppu_addr), .oe_b(nes_ppu_rd), .we_b(nes_ppu_wr),
      .din_b(nes_ppu_wrdata), .dout_b(nes_backend_ppu_data), .sd_clk(nes_sd_clk), .sd_a(nes_sd_a),
      .sd_ba(nes_sd_ba), .sd_ras_n(nes_sd_ras_n), .sd_cas_n(nes_sd_cas_n),
      .sd_we_n(nes_sd_we_n), .sd_dq(nes_sd_dq));

  wire stream_valid, loader_in_ready;
  wire [7:0] stream_data;
  fifo_async #(.Width(8), .Depth(4096)) stream_fifo (
      .wclk(clk_bus), .wrst(stream_wreset), .in_valid(st_valid), .in_ready(stream_ready),
      .in_data(st_data), .wlevel(stream_level), .rclk(md_clk), .rrst(stream_rreset),
      .out_valid(stream_valid), .out_ready(loader_in_ready), .out_data(stream_data));
  wire ld_valid, ld_ready, ld_rsp, ld_rsp_ready;
  wire [20:0] ld_addr;
  wire [31:0] ld_data;
  retro_loader loader (.clk(md_clk), .rst(reset), .begin_load(loader_begin),
      .abort_load(loader_abort), .commit_load(loader_commit), .system(loader_system),
      .length(loader_length), .all_idle(loader_all_idle), .fifo_empty(loader_fifo_empty),
      .init_ready(loader_init_ready), .backend_valid(loader_backend_valid),
      .backend_fail(loader_backend_fail), .in_valid(stream_valid), .in_ready(loader_in_ready),
      .in_data(stream_data), .flush_fifo(loader_flush), .ready(loader_ready),
      .loading(loader_loading), .done(loader_done), .failed(loader_failed), .run(loader_run),
      .selected(loader_selected), .received(loader_received), .memory_idle(loader_memory_idle),
      .mem_valid(ld_valid), .mem_ready(ld_ready), .mem_addr(ld_addr), .mem_wdata(ld_data),
      .mem_rsp_valid(ld_rsp), .mem_rsp_ready(ld_rsp_ready));
  wire md_valid, md_ready, md_write, md_rsp, md_rsp_ready;
  wire [20:0] md_physical_addr;
  wire [31:0] md_physical_data, client_rdata;
  wire [3:0] md_mask;
  retro_md_memory md_adapter (.clk(md_clk), .rst(reset), .enable(md_adapter_enable),
      .idle(md_adapter_idle), .fault(md_adapter_fault), .mem_req(md_req), .mem_ack(md_adapter_ack),
      .mem_addr(md_addr), .mem_we(md_we), .mem_be(md_be), .mem_wdata(md_wdata),
      .mem_rdata(md_adapter_rdata), .req_valid(md_valid), .req_ready(md_ready),
      .req_write(md_write), .req_addr(md_physical_addr), .req_wdata(md_physical_data),
      .req_mask(md_mask), .rsp_valid(md_rsp), .rsp_ready(md_rsp_ready), .rsp_rdata(client_rdata));
  wire [1:0] client_ready, client_rsp;
  assign {ld_ready, md_ready} = client_ready;
  assign {ld_rsp, md_rsp} = client_rsp;
  wire mux_valid, mux_ready, mux_write, mux_rsp, mux_rsp_ready;
  wire [20:0] mux_addr;
  wire [31:0] mux_data, mux_rdata;
  wire [3:0] mux_mask;
  retro_mem_mux ownership (.clk(md_clk), .rst(reset), .owner(fabric_owner), .idle(fabric_idle),
      .req_valid({ld_valid, md_valid}), .req_ready(client_ready), .req_write({1'b1, md_write}),
      .req_addr('{md_physical_addr, ld_addr}), .req_wdata('{md_physical_data, ld_data}),
      .req_mask('{md_mask, 4'b1111}), .rsp_valid(client_rsp),
      .rsp_ready({ld_rsp_ready, md_rsp_ready}), .rsp_rdata(client_rdata),
      .mem_valid(mux_valid), .mem_ready(mux_ready), .mem_write(mux_write), .mem_addr(mux_addr),
      .mem_wdata(mux_data), .mem_mask(mux_mask), .mem_rsp_valid(mux_rsp),
      .mem_rsp_ready(mux_rsp_ready), .mem_rdata(mux_rdata));
  wire phy_valid, phy_ready, phy_write, phy_rsp, phy_rsp_ready;
  wire [20:0] phy_addr;
  wire [31:0] phy_data, phy_rdata;
  retro_mem_lanes lanes (.clk(md_clk), .rst(reset), .req_valid(mux_valid), .req_ready(mux_ready),
      .req_write(mux_write), .req_addr(mux_addr), .req_wdata(mux_data), .req_mask(mux_mask),
      .rsp_valid(mux_rsp), .rsp_ready(mux_rsp_ready), .rsp_rdata(mux_rdata),
      .mem_valid(phy_valid), .mem_ready(phy_ready), .mem_write(phy_write), .mem_addr(phy_addr),
      .mem_wdata(phy_data), .mem_rsp_valid(phy_rsp), .mem_rsp_ready(phy_rsp_ready),
      .mem_rdata(phy_rdata));
  retro_sdram #(.InitCycles(10740), .RefreshCycles(375), .Trcd(1), .Trp(1),
      .Trfc(4), .Tras(3), .Twr(1)) generic_backend (
      .clk(md_clk), .rst(reset), .initialized(generic_initialized), .req_valid(phy_valid),
      .req_ready(phy_ready), .req_write(phy_write), .req_addr(phy_addr), .req_wdata(phy_data),
      .rsp_valid(phy_rsp), .rsp_ready(phy_rsp_ready), .rsp_rdata(phy_rdata),
      .sd_a(generic_sd_a), .sd_ba(generic_sd_ba), .sd_ras_n(generic_sd_ras_n),
      .sd_cas_n(generic_sd_cas_n), .sd_we_n(generic_sd_we_n), .sd_dq_in(generic_dq_in),
      .sd_dq_out(generic_dq_out), .sd_dq_oe(generic_dq_oe), .sd_dq_oe_next());

  wire [2:0] pixel_valid, pixel_pop;
  wire [28:0] pixel_data [3];
  wire md_we_pixel, snes_we_pixel;
  wire [8:0] md_x, snes_px;
  wire [7:0] md_y, snes_py;
  wire [14:0] md_rgb, snes_px_rgb;
  wire md_frame, snes_frame;
  retro_pixels md_pixels (.clk(md_clk), .rst(reset), .active(select == 2),
      .pixel_ce(md_pixel), .hs_n(md_hs), .vs_n(md_vs), .hde(md_hde), .vde(md_vde),
      .unsupported(md_interlace), .rgb({md_red,1'b0,md_green,1'b0,md_blue,1'b0}),
      .we(md_we_pixel), .x(md_x), .y(md_y), .data(md_rgb), .frame(md_frame),
      .overflow(md_video_overflow));
  retro_pixels snes_pixels (.clk(snes_clk), .rst(reset), .active(select == 3),
      .pixel_ce(snes_pixel), .hs_n(~snes_hs), .vs_n(~snes_vs), .hde(snes_hde), .vde(snes_vde),
      .unsupported(snes_interlace || snes_highres), .rgb(snes_rgb), .we(snes_we_pixel),
      .x(snes_px), .y(snes_py), .data(snes_px_rgb), .frame(snes_frame),
      .overflow(snes_video_overflow));
  wire [23:0] nes_rgb_value = nes_rgb({nes_emphasis, nes_color});
  fifo_async #(.Width(29), .Depth(512)) nes_pixels_fifo (
      .wclk(nes_clk), .wrst(reset), .in_valid(nes_pixel_ce && select == 1),
      .in_ready(pixel_fifo_ready[0]), .in_data({nes_cycle, nes_line[7:0],
          nes_rgb_value[23:20], nes_rgb_value[15:12], nes_rgb_value[7:4]}), .wlevel(pixel_level[0]),
      .rclk(md_clk), .rrst(reset), .out_valid(pixel_valid[0]), .out_ready(pixel_pop[0]),
      .out_data(pixel_data[0]));
  fifo_async #(.Width(29), .Depth(512)) md_pixels_fifo (
      .wclk(md_clk), .wrst(reset), .in_valid(md_we_pixel), .in_ready(pixel_fifo_ready[1]),
      .in_data({md_x, md_y, md_rgb[14:11], md_rgb[9:6], md_rgb[4:1]}),
      .wlevel(pixel_level[1]), .rclk(md_clk), .rrst(reset), .out_valid(pixel_valid[1]),
      .out_ready(pixel_pop[1]), .out_data(pixel_data[1]));
  fifo_async #(.Width(29), .Depth(512)) snes_pixels_fifo (
      .wclk(snes_clk), .wrst(reset), .in_valid(snes_we_pixel), .in_ready(pixel_fifo_ready[2]),
      .in_data({snes_px, snes_py, snes_px_rgb[14:11], snes_px_rgb[9:6], snes_px_rgb[4:1]}),
      .wlevel(pixel_level[2]), .rclk(md_clk), .rrst(reset), .out_valid(pixel_valid[2]),
      .out_ready(pixel_pop[2]), .out_data(pixel_data[2]));
  wire [1:0] source_index = select == 1 ? 0 : select == 2 ? 1 : 2;
  assign pixel_pop = select == 0 ? 3'b000 : 3'b001 << source_index;
  wire [28:0] presentation_pixel = pixel_data[source_index];
  vpx_t timing_pixel, framebuffer_pixel;
  video_timing timing (.clk(clk_pix), .rst(rst_pix), .ce(1'b1), .px(timing_pixel));
  retro_framebuffer #(.ChannelBits(3)) shared_framebuffer (
      .wclk(md_clk), .we(select != 0 && pixel_valid[source_index]),
      .wx(presentation_pixel[28:20]), .wy(presentation_pixel[19:12]),
      .wdata(presentation_pixel[11:0]), .clk(clk_pix), .clear(video_clear),
      .visible(video_visible), .wide(video_wide), .tall(video_tall),
      .px_in(timing_pixel), .px_out(framebuffer_pixel));
  hdmi_tx display (.clk_pix(clk_pix), .clk_5x(clk_5x), .px(framebuffer_pixel),
      .pad_p(hdmi_p), .pad_n(hdmi_n));
endmodule

`default_nettype wire
