// SPDX-License-Identifier: MIT
`default_nettype none

// Source-domain 48 kHz capture CE -> stable bundled-data pixel-domain transfer.
// sample_valid is a LEVEL for a held, qualified sample, not a one-cycle ready.
// Example: NES unsigned APU -> signed via {~raw[15],raw[14:0]}, mono to L/R;
// MD signed16 held L/R; SNES hold signed16 L/R on service-domain sample-ready.
// Zero-order hold only: no anti-alias/interpolation filter is claimed.
// Assert rst_src AND rst_pix on system changes; hold source reset >=4 pixel cycles.
// cdc_word requires >=4 destination cycles between strobes: 48 kHz vs 25.1875 MHz
// provides >500. ClockHz is the ACTUAL source clock (21.477/53.693/85.9/100 MHz).
module retro_audio_cdc #(
    parameter int unsigned ClockHz = 100000000,
    parameter int unsigned PixelHz = 25187500
) (
    input wire clk_src,
    input wire rst_src,
    input wire sample_valid,
    input wire signed [15:0] sample_l,
    input wire signed [15:0] sample_r,
    input wire clk_pix,
    input wire rst_pix,
    output logic audio_valid = 1'b0,
    output logic signed [15:0] audio_l = '0,
    output logic signed [15:0] audio_r = '0
);
  localparam int PhaseWidth = $clog2(ClockHz);
  logic [PhaseWidth-1:0] phase = '0;
  wire [PhaseWidth:0] next_phase = {1'b0, phase} + (PhaseWidth+1)'(48000);
  wire capture = next_phase >= (PhaseWidth+1)'(ClockHz);
  always_ff @(posedge clk_src) begin
    if (rst_src) phase <= '0;
    else phase <= PhaseWidth'(capture ? next_phase - (PhaseWidth+1)'(ClockHz) : next_phase);
  end

  wire [32:0] transferred;
  wire transferred_stb;
  cdc_word #(.Width(33)) u_sample (
      .sclk(clk_src), .stb(capture && !rst_src),
      .d(sample_valid ? {1'b1, sample_l, sample_r} : 33'b0),
      .dclk(clk_pix), .q(transferred), .q_stb(transferred_stb));

  logic [2:0] reset_guard = '0;
  always_ff @(posedge clk_pix) begin
    if (rst_pix) begin
      reset_guard <= '0;
      audio_valid <= 1'b0;
      audio_l <= '0;
      audio_r <= '0;
    end else if (!reset_guard[2]) reset_guard <= reset_guard + 1'b1;
    else if (transferred_stb) begin
      audio_valid <= transferred[32];
      audio_l <= transferred[31:16];
      audio_r <= transferred[15:0];
    end
  end
`ifndef SYNTHESIS
  initial begin
    assert (ClockHz >= 48000 && ClockHz <= 200000000);
    assert (PixelHz >= 4 * 48000);
  end
`endif
endmodule
