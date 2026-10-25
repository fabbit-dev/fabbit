`default_nettype none

// Shared 320x240 presentation memory, one write clock (after source FIFOs),
// one 640x480 pixel clock. Linear address avoids 512-wide BRAM waste. NTSC
// 256-wide sources are centered; 320-wide fills width. 224-line sources get bars.
// Caller snapshots width/height across domains ONLY while blanked/reset, not bitwise
// sync during live writes. Caller keeps visible=0 until a complete frame arrives;
// clear only blanks the read pipeline, it neither clears RAM nor counts a frame.
// Single buffer, same tearing limitation as existing NES video_fb_scale. Not a
// high-res/interlace solution, not HDMI audio. SNES 512 half-dot samples require
// a deliberate progressive low-res decimator before this 320-wide memory.
// RGB333 default bounds BRAM cost for three cores; RGB444 is an optional measured
// alternative. Quantization loses low bits; no dithering or higher-fidelity claim.
module retro_framebuffer
  import video_pkg::*;
#(
    parameter int ChannelBits = 3
)
(
    input  wire        wclk,
    input  wire        we,
    input  wire [8:0] wx,
    input  wire [7:0] wy,
    input  wire [11:0] wdata,
    input  wire        clk,
    input  wire        clear,
    input  wire        visible,
    input  wire        wide,
    input  wire        tall,
    input  vpx_t       px_in,
    output vpx_t       px_out
);
  initial begin
    if (ChannelBits != 3 && ChannelBits != 4)
      $error("retro_framebuffer supports RGB333 or RGB444 only");
  end
  wire [16:0] write_addr = 17'(wy) * 17'd320 + 17'(wx);
  wire [11:0] left_edge = wide ? 12'd0 : 12'd64;
  wire [11:0] top_edge = tall ? 12'd0 : 12'd16;
  wire [11:0] dx = px_in.x - left_edge;
  wire [11:0] dy = px_in.y - top_edge;
  wire in_window = visible && !clear && px_in.de && px_in.x >= left_edge &&
                   px_in.x < (wide ? 12'd640 : 12'd576) && px_in.y >= top_edge &&
                   px_in.y < (tall ? 12'd480 : 12'd464);
  wire [16:0] read_addr = 17'(dy >> 1) * 17'd320 + 17'(dx >> 1);
  localparam int DataBits = ChannelBits * 3;
  wire [DataBits-1:0] write_data = {wdata[11-:ChannelBits], wdata[7-:ChannelBits],
                                   wdata[3-:ChannelBits]};
  wire [DataBits-1:0] read_data;
  function automatic logic [7:0] expand(input logic [ChannelBits-1:0] c);
    if (ChannelBits == 3) return {3'(c), 3'(c), 2'(c >> 1)};
    return {4'(c), 4'(c)};
  endfunction
  if (ChannelBits == 3) begin : g_packed
    // Force 4096x9 native BRAM aspect ratio: default monolithic inference uses
    // 27 tiles here despite capacity for 19. Bank select has the SAME one-edge
    // read latency as each bank; it is not an extra video pipeline stage.
    wire [8:0] bank_data [19];
    logic [4:0] bank_q = '0;
    always_ff @(posedge clk) if (in_window) bank_q <= read_addr[16:12];
    for (genvar bank = 0; bank < 19; bank++) begin : g_bank
      ram_sdp #(.Width(9), .Depth(4096)) memory (
          .wclk(wclk), .we(we && wx < 320 && wy < 240 && write_addr[16:12] == 5'(bank)),
          .waddr(write_addr[11:0]), .wdata(write_data), .rclk(clk),
          .re(in_window && read_addr[16:12] == 5'(bank)), .raddr(read_addr[11:0]),
          .rdata(bank_data[bank]));
    end
    assign read_data = bank_q < 19 ? bank_data[bank_q] : 9'd0;
  end else begin : g_rgb444
    ram_sdp #(.Width(DataBits), .Depth(76800)) memory (
        .wclk(wclk), .we(we && wx < 320 && wy < 240), .waddr(write_addr), .wdata(write_data),
        .rclk(clk), .re(in_window), .raddr(read_addr), .rdata(read_data));
  end
  vpx_t stage;
  logic window = 1'b0;
  always_ff @(posedge clk) begin
    stage <= px_in;
    window <= in_window;
    px_out <= vpx_rgb(stage,
        window && !clear ? expand(read_data[DataBits-1-:ChannelBits]) : 8'd0,
        window && !clear ? expand(read_data[2*ChannelBits-1-:ChannelBits]) : 8'd0,
        window && !clear ? expand(read_data[ChannelBits-1:0]) : 8'd0);
  end
endmodule
