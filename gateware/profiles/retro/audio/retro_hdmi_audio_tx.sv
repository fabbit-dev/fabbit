// SPDX-License-Identifier: MIT
`default_nettype none

// HDMI 640x480/VIC1 using the EXISTING vpx_t coordinates/sync and tmds_phy_se.
// One pixel edge to lane_debug (same video latency as common/hdmi_tx), then PHY.
// audio_valid is a level qualifying held signed16 stereo in clk_pix. No generated
// audio clock: NCO CE at 48 kHz, measured 48-sample CTS, N=6144. Missing audio = 0.
// Reset on system switch to flush old samples. Up to four assembling + four pending
// samples; normal 800x525 timing has ample packet slots. overflow is sticky/fail-visible.
module retro_hdmi_audio_tx
  import video_pkg::*;
#(
    parameter logic [3:0] InvMask = 4'b0000,
    parameter int unsigned PixelHz = 25187500
) (
    input wire clk_pix,
    input wire clk_5x,
    input wire rst_pix,
    input vpx_t px,
    input wire audio_valid,
    input wire signed [15:0] audio_l,
    input wire signed [15:0] audio_r,
    output wire [3:0] pad_p,
    output wire [3:0] pad_n,
    output wire [9:0] lane_debug [3],
    output wire sample_ce,
    output logic overflow = 1'b0
);
  localparam int PhaseWidth = $clog2(PixelHz);
  logic [PhaseWidth-1:0] phase = '0;
  wire [PhaseWidth:0] next_phase = {1'b0, phase} + (PhaseWidth+1)'(48000);
  assign sample_ce = !rst_pix && next_phase >= (PhaseWidth+1)'(PixelHz);

  logic [15:0] cts_cycles = '0;
  logic [5:0] acr_samples = '0;
  logic [19:0] cts = 20'(PixelHz / 1000);
  logic acr_due = 1'b0;
  logic [2:0] info_due = 3'b111;
  logic [31:0] filling [3];
  logic [31:0] pending [4];
  logic [1:0] fill_count = '0;
  logic pending_ready = 1'b0;
  logic [7:0] iec_frame = '0;

  wire island = !rst_pix && px.x >= 654 && px.x < 750;
  wire packet_load = !rst_pix && (px.x == 653 || px.x == 685 || px.x == 717);
  wire take_acr = packet_load && acr_due;
  wire take_audio = packet_load && !acr_due && pending_ready;
  wire take_aif = packet_load && !acr_due && !pending_ready && info_due[0];
  wire take_avi = packet_load && !acr_due && !pending_ready && !info_due[0] && info_due[1];
  wire take_spd = packet_load && !acr_due && !pending_ready && !info_due[0] &&
                  !info_due[1] && info_due[2];

  always_ff @(posedge clk_pix) begin
    if (rst_pix) begin
      phase <= '0;
      cts_cycles <= '0;
      acr_samples <= '0;
      cts <= 20'(PixelHz / 1000);
      acr_due <= 1'b0;
      info_due <= 3'b111;
      fill_count <= '0;
      pending_ready <= 1'b0;
      iec_frame <= '0;
      overflow <= 1'b0;
    end else begin
      phase <= PhaseWidth'(sample_ce ? next_phase - (PhaseWidth+1)'(PixelHz) : next_phase);
      cts_cycles <= cts_cycles + 1'b1;
      if (take_acr) acr_due <= 1'b0;
      if (take_aif) info_due[0] <= 1'b0;
      if (take_avi) info_due[1] <= 1'b0;
      if (take_spd) info_due[2] <= 1'b0;
      if (px.sof) info_due <= 3'b111;
      if (take_audio) begin
        pending_ready <= 1'b0;
        iec_frame <= iec_frame == 188 ? 8'd0 : iec_frame + 8'd4;
      end
      if (sample_ce) begin
        if (acr_samples == 47) begin
          acr_samples <= '0;
          cts_cycles <= '0;
          cts <= {4'b0, cts_cycles} + 20'd1;
          acr_due <= 1'b1;
        end else acr_samples <= acr_samples + 1'b1;
        if (fill_count != 3) begin
          filling[fill_count] <= audio_valid ? {audio_l, audio_r} : 32'b0;
          fill_count <= fill_count + 1'b1;
        end else begin
          fill_count <= '0;
          if (!pending_ready || take_audio) begin
            for (int i = 0; i < 3; i++) pending[i] <= filling[i];
            pending[3] <= audio_valid ? {audio_l, audio_r} : 32'b0;
            pending_ready <= 1'b1;
          end else overflow <= 1'b1;
        end
      end
    end
  end

  // IEC60958 consumer LPCM: copyright not asserted, channel 1/2, 48 kHz,
  // word length 16 of max20 (0010), original sample frequency unspecified.
  function automatic logic channel_status(input logic [7:0] frame, input logic right);
    case (frame)
      2: return 1'b1;
      20: return !right;
      21: return right;
      25: return 1'b1;
      33: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  logic [23:0] header;
  logic [55:0] sub [4];
  logic [7:0] bytes_info [28];
  logic [7:0] checksum;
  logic [7:0] current_frame;
  logic cs_l, cs_r;
  logic [23:0] sample_l24, sample_r24;
  always_comb begin
    header = '0; // deterministic HDMI Null packet when nothing is pending
    for (int i = 0; i < 4; i++) sub[i] = '0;
    for (int i = 0; i < 28; i++) bytes_info[i] = '0;
    checksum = '0;
    current_frame = '0;
    cs_l = 1'b0;
    cs_r = 1'b0;
    sample_l24 = '0;
    sample_r24 = '0;
    if (take_acr) begin
      header = 24'h000001;
      // SB0 reserved, CTS[19:16], CTS[15:8], CTS[7:0], N[19:16], N[15:8], N[7:0].
      for (int i = 0; i < 4; i++) sub[i] = {8'h00, 8'h18, 8'h00, cts[7:0],
                                                            cts[15:8], 4'b0, cts[19:16], 8'h00};
    end else if (take_audio) begin
      header = 24'h000f02; // layout0, all four sample-present bits
      for (int i = 0; i < 4; i++) begin
        current_frame = iec_frame + 8'(i);
        header[20+i] = current_frame == 0;
        cs_l = channel_status(current_frame, 1'b0);
        cs_r = channel_status(current_frame, 1'b1);
        sample_l24 = {pending[i][31:16], 8'b0};
        sample_r24 = {pending[i][15:0], 8'b0};
        sub[i] = {^{sample_r24, cs_r}, cs_r, 2'b00,
                  ^{sample_l24, cs_l}, cs_l, 2'b00, sample_r24, sample_l24};
      end
    end else begin
      if (take_aif) begin
        header = 24'h0a0184;
        bytes_info[1] = 8'h01; // two channels, stream supplies LPCM/rate/size
      end else if (take_avi) begin
        header = 24'h0d0282;
        bytes_info[2] = 8'h18; // 4:3 picture, active aspect = picture
        bytes_info[4] = 8'h01; // VIC1, RGB default full range
      end else if (take_spd) begin
        header = 24'h190183;
        // Eight vendor + sixteen product ASCII bytes; source device = game.
        bytes_info[1] = "F"; bytes_info[2] = "a"; bytes_info[3] = "b";
        bytes_info[4] = "b"; bytes_info[5] = "i"; bytes_info[6] = "t";
        bytes_info[9] = "R"; bytes_info[10] = "E"; bytes_info[11] = "T";
        bytes_info[12] = "R"; bytes_info[13] = "O";
        bytes_info[25] = 8'h08;
      end
      checksum = header[7:0] + header[15:8] + header[23:16];
      for (int i = 1; i < 28; i++) checksum = checksum + bytes_info[i];
      bytes_info[0] = 8'd0 - checksum;
      for (int i = 0; i < 4; i++)
        for (int j = 0; j < 7; j++) sub[i][8*j +: 8] = bytes_info[7*i+j];
    end
  end

  wire [8:0] packet_bits;
  retro_hdmi_packet u_packet (.clk_pix, .rst_pix, .load(packet_load), .island,
                              .header, .sub, .data_bits(packet_bits));

  function automatic logic [9:0] terc4(input logic [3:0] nibble);
    case (nibble)
      0: return 10'b1010011100; 1: return 10'b1001100011;
      2: return 10'b1011100100; 3: return 10'b1011100010;
      4: return 10'b0101110001; 5: return 10'b0100011110;
      6: return 10'b0110001110; 7: return 10'b0100111100;
      8: return 10'b1011001100; 9: return 10'b0100111001;
      10: return 10'b0110011100; 11: return 10'b1011000110;
      12: return 10'b1010001110; 13: return 10'b1001110001;
      14: return 10'b0101100011; 15: return 10'b1011000011;
      default: return 10'b1010011100;
    endcase
  endfunction

  wire island_preamble = px.x >= 644 && px.x < 652;
  wire island_guard = (px.x >= 652 && px.x < 654) || (px.x >= 750 && px.x < 752);
  wire next_video = px.y < 479 || px.y == 524;
  wire video_preamble = next_video && px.x >= 790 && px.x < 798;
  wire video_guard = next_video && px.x >= 798 && px.x < 800;
  wire [9:0] encoded [3];
  logic [9:0] auxiliary [3];
  logic video_selected = 1'b0;
  tmds_encoder u_b (.clk(clk_pix), .ce(1'b1), .d(px.b), .c({px.vs, px.hs}),
                    .de(px.de && !rst_pix), .q(encoded[0]));
  tmds_encoder u_g (.clk(clk_pix), .ce(1'b1), .d(px.g),
                    .c({1'b0, !rst_pix && (island_preamble || video_preamble)}),
                    .de(px.de && !rst_pix), .q(encoded[1]));
  tmds_encoder u_r (.clk(clk_pix), .ce(1'b1), .d(px.r),
                    .c({1'b0, !rst_pix && island_preamble}),
                    .de(px.de && !rst_pix), .q(encoded[2]));

  always_ff @(posedge clk_pix) begin
    video_selected <= !rst_pix && (px.de || (!island && !island_guard && !video_guard));
    auxiliary[0] <= terc4({1'b1, packet_bits[0], px.vs, px.hs});
    auxiliary[1] <= terc4(packet_bits[4:1]);
    auxiliary[2] <= terc4(packet_bits[8:5]);
    if (island_guard) begin
      auxiliary[0] <= terc4({2'b11, px.vs, px.hs});
      auxiliary[1] <= 10'b0100110011;
      auxiliary[2] <= 10'b0100110011;
    end else if (video_guard) begin
      auxiliary[0] <= 10'b1011001100;
      auxiliary[1] <= 10'b0100110011;
      auxiliary[2] <= 10'b1011001100;
    end
    if (rst_pix) for (int i = 0; i < 3; i++) auxiliary[i] <= 10'b1101010100;
  end
  for (genvar i = 0; i < 3; i++) begin : g_lane
    assign lane_debug[i] = video_selected ? encoded[i] : auxiliary[i];
  end
  tmds_phy_se #(.InvMask(InvMask)) u_phy (.clk_pix, .clk_5x, .lane(lane_debug), .pad_p, .pad_n);
`ifndef SYNTHESIS
  initial assert (PixelHz >= 25000000 && PixelHz <= 26000000);
`endif
endmodule
