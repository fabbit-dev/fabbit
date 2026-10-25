// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// Three native writers, one RGB333 presentation buffer, common timing/DVI.
// SNES native 512 half-dot samples decimated 2:1 to progressive 256; interlace
// rejected, never treated as another frame. Source FIFO full is sticky fault.
module retro_video (
    input wire bus_clk,rst,
    input wire [1:0] selected,
    input wire running,
    input wire audio_valid,
    input wire signed [15:0] audio_l,audio_r,
  input wire nes_clk,nes_we,
    input wire [7:0] nes_x,nes_y,
    input wire [8:0] nes_index,
    input wire md_clk,md_pixel,md_hs,md_vs,md_hde,md_vde,md_interlace,
    input wire [3:0] md_r,md_g,md_b,
    input wire [1:0] md_resolution,
    input wire snes_clk,snes_pixel,snes_hde,snes_vde,snes_interlace,snes_v224,
    input wire [8:0] snes_x,snes_y,
    input wire [14:0] snes_rgb,
  input wire clk_pix,clk_5x,rst_pix,
    output wire [3:0] hdmi_p,hdmi_n,
    output wire fault
);
  import video_pkg::*;
  import nes_palette_pkg::*;
  wire [23:0] nes_color=nes_rgb(nes_index);
  wire nes_active,md_active,snes_active;
  sync_bit nes_active_sync (.clk(nes_clk),.d(running && selected==1),.q(nes_active));
  sync_bit md_active_sync (.clk(md_clk),.d(running && selected==2),.q(md_active));
  sync_bit snes_active_sync (.clk(snes_clk),.d(running && selected==3),.q(snes_active));
  wire md_we;
  wire [8:0] md_x;
  wire [7:0] md_y;
  wire [14:0] md_color;
  wire md_overflow;
  retro_pixels md_positions (.clk(md_clk),.rst,.active(md_active),
      .pixel_ce(md_pixel),.hs_n(md_hs),.vs_n(md_vs),.hde(md_hde),.vde(md_vde),
      .unsupported(md_interlace),.rgb({md_r,1'b0,md_g,1'b0,md_b,1'b0}),
      .we(md_we),.x(md_x),.y(md_y),.data(md_color),.frame(),.overflow(md_overflow));
  wire [2:0] valid,pop,space;
  wire [28:0] pixels [3];
  wire [2:0] writes={snes_pixel && snes_hde && snes_vde && !snes_x[0] &&
                     !snes_interlace && snes_active,
                     md_we,nes_we && nes_active};
  wire [28:0] inputs [3];
  assign inputs[0]={1'b0,nes_x,nes_y,nes_color[23:20],nes_color[15:12],nes_color[7:4]};
  assign inputs[1]={md_x,md_y,md_color[14:11],md_color[9:6],md_color[4:1]};
  assign inputs[2]={1'b0,snes_x[8:1],snes_y[7:0],
                    snes_rgb[4:1],snes_rgb[9:6],snes_rgb[14:11]};
  wire [2:0] source_clocks={snes_clk,md_clk,nes_clk};
  wire [2:0] overflow;
  for (genvar p=0;p<3;p++) begin : g_source
    logic source_overflow=0;
    assign overflow[p]=source_overflow;
    always_ff @(posedge source_clocks[p])
      if (rst) source_overflow<=0;
      else if (writes[p] && !space[p]) source_overflow<=1;
    fifo_async #(.Width(29),.Depth(512)) fifo (
        .wclk(source_clocks[p]),.wrst(rst),.in_valid(writes[p]),.in_ready(space[p]),
        .in_data(inputs[p]),.wlevel(),.rclk(bus_clk),.rrst(rst),.out_valid(valid[p]),
        .out_ready(pop[p]),.out_data(pixels[p]));
  end
  // Drain unselected FIFOs as well: no stale previous-owner frame after a switch.
  assign pop=3'b111;
  wire [1:0] idx=selected-1'b1;
  wire [28:0] pixel=pixels[idx];
  wire we=selected!=0 && running && valid[idx];
  logic seen_frame=0;
  logic first_frame=0;
  always_ff @(posedge bus_clk)
    if (rst || !running) begin seen_frame<=0;first_frame<=0;end
    else if (we && pixel[28:20]==0 && pixel[19:12]==0) begin
      first_frame<=1;
      if (first_frame) seen_frame<=1;
    end
  wire visible,wide,tall;
  sync_bit vis_sync (.clk(clk_pix),.d(seen_frame && running),.q(visible));
  wire [1:0] md_mode_bus;
  wire snes_tall_bus;
  cdc_word #(.Width(2)) md_mode_sync (.sclk(md_clk),.stb(md_we && md_x==0 && md_y==0),
      .d(md_resolution),.dclk(bus_clk),.q(md_mode_bus),.q_stb());
  cdc_word #(.Width(1)) snes_mode_sync (.sclk(snes_clk),
      .stb(writes[2] && snes_x==0 && snes_y==0),.d(!snes_v224),
      .dclk(bus_clk),.q(snes_tall_bus),.q_stb());
  wire [1:0] presentation_mode;
  cdc_word #(.Width(2)) presentation_config (.sclk(bus_clk),
      .stb(we && pixel[28:20]==0 && pixel[19:12]==0),
      .d({selected==1 || (selected==2 ? md_mode_bus[1] : snes_tall_bus),
          selected==2 && md_mode_bus[0]}),.dclk(clk_pix),.q(presentation_mode),.q_stb());
  assign {tall,wide}=presentation_mode;
  vpx_t timing,display;
  video_timing timing_generator (.clk(clk_pix),.rst(rst_pix),.ce(1'b1),.px(timing));
  retro_framebuffer framebuffer (.wclk(bus_clk),.we,.wx(pixel[28:20]),.wy(pixel[19:12]),
      .wdata(pixel[11:0]),.clk(clk_pix),.clear(!visible),.visible,.wide,.tall,
      .px_in(timing),.px_out(display));
  wire audio_pixel_valid;
  wire signed [15:0] audio_pixel_l,audio_pixel_r;
  logic [5:0] audio_reset_guard=0;
  always_ff @(posedge bus_clk)
    if (rst || !running) audio_reset_guard<=0;
    else if (!(&audio_reset_guard)) audio_reset_guard<=audio_reset_guard+1'b1;
  wire audio_reset=!( &audio_reset_guard);
  wire audio_reset_pixel;
  sync_bit audio_reset_sync (.clk(clk_pix),.d(audio_reset),.q(audio_reset_pixel));
  retro_audio_cdc #(.ClockHz(100000000),.PixelHz(25187500)) audio_transfer (
      .clk_src(bus_clk),.rst_src(audio_reset),.sample_valid(audio_valid),
      .sample_l(audio_l),.sample_r(audio_r),.clk_pix,.rst_pix(rst_pix || audio_reset_pixel),
      .audio_valid(audio_pixel_valid),.audio_l(audio_pixel_l),.audio_r(audio_pixel_r));
  wire audio_overflow;
  retro_hdmi_audio_tx #(.PixelHz(25187500)) transmitter (
      .clk_pix,.clk_5x,.rst_pix(rst_pix || audio_reset_pixel),.px(display),
      .audio_valid(audio_pixel_valid),.audio_l(audio_pixel_l),.audio_r(audio_pixel_r),
      .pad_p(hdmi_p),.pad_n(hdmi_n),.lane_debug(),.sample_ce(),.overflow(audio_overflow));
  assign fault=(|overflow) || md_overflow || audio_overflow;
endmodule
`default_nettype wire
