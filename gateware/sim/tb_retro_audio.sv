// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
`default_nettype none
// Independent lane decoder: BCH syndrome, info checksums, IEC60958, ACR, video.
module tb_retro_audio;
  import video_pkg::*;
  logic clk_pix = 0, clk_5x = 0, rst_pix = 1;
  always #20 clk_pix = ~clk_pix;
  always #4 clk_5x = ~clk_5x;
  vpx_t px;
  logic audio_valid = 1;
  logic signed [15:0] audio_l = -32768, audio_r = 32767;
  wire [3:0] pad_p, pad_n;
  wire [9:0] lane [3];
  wire sample_ce, overflow;
  retro_hdmi_audio_tx dut (.clk_pix, .clk_5x, .rst_pix, .px, .audio_valid,
      .audio_l, .audio_r, .pad_p, .pad_n, .lane_debug(lane), .sample_ce, .overflow);
  wire [9:0] reference_video [3];
  tmds_encoder ref_b (.clk(clk_pix), .ce(1'b1), .d(px.b), .c({px.vs,px.hs}),
                      .de(px.de && !rst_pix), .q(reference_video[0]));
  tmds_encoder ref_g (.clk(clk_pix), .ce(1'b1), .d(px.g), .c(2'b0),
                      .de(px.de && !rst_pix), .q(reference_video[1]));
  tmds_encoder ref_r (.clk(clk_pix), .ce(1'b1), .d(px.r), .c(2'b0),
                      .de(px.de && !rst_pix), .q(reference_video[2]));

  function automatic logic [3:0] decode_terc(input logic [9:0] code);
    case (code)
      10'b1010011100: return 0; 10'b1001100011: return 1;
      10'b1011100100: return 2; 10'b1011100010: return 3;
      10'b0101110001: return 4; 10'b0100011110: return 5;
      10'b0110001110: return 6; 10'b0100111100: return 7;
      10'b1011001100: return 8; 10'b0100111001: return 9;
      10'b0110011100: return 10; 10'b1011000110: return 11;
      10'b1010001110: return 12; 10'b1001110001: return 13;
      10'b0101100011: return 14; 10'b1011000011: return 15;
      default: $fatal(1, "not TERC4 %b", code);
    endcase
    return 0;
  endfunction
  function automatic logic [9:0] control_code(input logic [1:0] control_bits);
    case (control_bits)
      0: return 10'b1101010100; 1: return 10'b0010101011;
      2: return 10'b0101010100; 3: return 10'b1010101011;
      default: return 10'b1101010100;
    endcase
  endfunction
  // Independent long-division syndrome (all bits including transmitted ECC -> 0).
  function automatic logic [7:0] syndrome(input logic [63:0] bits_in, input int count);
    logic [7:0] state_ecc;
    logic feedback;
    state_ecc = 0;
    for (int i = 0; i < count; i++) begin
      feedback = bits_in[i] ^ state_ecc[0];
      state_ecc = {1'b0, state_ecc[7:1]};
      if (feedback) state_ecc ^= 8'h83;
    end
    return state_ecc;
  endfunction
  function automatic logic expected_cs(input int frame_index, input bit right);
    return frame_index == 2 || frame_index == (right ? 21 : 20) ||
           frame_index == 25 || frame_index == 33;
  endfunction

  logic [31:0] decoded_header;
  logic [63:0] decoded_sub [4];
  logic [31:0] expected_samples [$];
  logic [31:0] expected_sample;
  logic [3:0] n0, n1, n2;
  int packets_audio = 0, packets_acr = 0, packets_aif = 0, packets_avi = 0, packets_spd = 0;
  int field_aif = 0, field_avi = 0, field_spd = 0;
  int sample_count = 0, received_samples = 0, frame_index = 0, b_blocks = 0;
  int cycles = 0, checksum_test, packet_pos, cts_value, sum_cts = 0;
  int cts_low = 0, cts_high = 0;
  int last_sample_cycle = 0;
  bit sampled;

  task automatic check_packet;
    assert (syndrome({32'b0, decoded_header}, 32) == 0) else $fatal(1, "header BCH");
    for (int i = 0; i < 4; i++)
      assert (syndrome(decoded_sub[i], 64) == 0) else $fatal(1, "subpacket BCH %0d", i);
    case (decoded_header[7:0])
      8'h00: ;
      8'h01: begin
        packets_acr++;
        // CTS is SB1..3; N is SB4..6, each big-endian within byte sequence.
        cts_value = int'({decoded_sub[0][11:8], decoded_sub[0][23:16], decoded_sub[0][31:24]});
        assert ({decoded_sub[0][35:32], decoded_sub[0][47:40], decoded_sub[0][55:48]} == 20'd6144)
          else $fatal(1, "N !=6144");
        assert (cts_value == 25187 || cts_value == 25188) else $fatal(1, "CTS %0d", cts_value);
        if (cts_value == 25187) cts_low++; else cts_high++;
        sum_cts += cts_value;
        for (int i = 1; i < 4; i++) assert (decoded_sub[i] == decoded_sub[0]);
      end
      8'h02: begin
        packets_audio++;
        assert (decoded_header[19:8] == 12'h00f) else $fatal(1, "layout/present");
        for (int i = 0; i < 4; i++) begin
          assert (expected_samples.size() > 0) else $fatal(1, "stale/double sample packet");
          expected_sample = expected_samples.pop_front();
          assert ({decoded_sub[i][23:8], decoded_sub[i][47:32]} == expected_sample)
            else $fatal(1, "audio %0d got %h expected %h", received_samples,
                         {decoded_sub[i][23:8], decoded_sub[i][47:32]}, expected_sample);
          assert (decoded_sub[i][7:0] == 0 && decoded_sub[i][31:24] == 0);
          assert (!decoded_sub[i][48] && !decoded_sub[i][49] &&
                  !decoded_sub[i][52] && !decoded_sub[i][53]);
          assert (decoded_sub[i][50] == expected_cs(frame_index, 0));
          assert (decoded_sub[i][54] == expected_cs(frame_index, 1));
          assert ((^decoded_sub[i][23:0] ^ ^decoded_sub[i][51:48]) == 0);
          assert ((^decoded_sub[i][47:24] ^ ^decoded_sub[i][55:52]) == 0);
          assert (decoded_header[20+i] == (frame_index == 0));
          if (frame_index == 0) b_blocks++;
          frame_index = frame_index == 191 ? 0 : frame_index + 1;
          received_samples++;
        end
      end
      8'h84, 8'h82, 8'h83: begin
        checksum_test = int'(decoded_header[7:0]) + int'(decoded_header[15:8]) +
                        int'(decoded_header[23:16]);
        for (int i = 0; i <= int'(decoded_header[23:16]); i++)
          checksum_test += int'(decoded_sub[i/7][8*(i%7) +: 8]);
        assert ((checksum_test & 255) == 0) else $fatal(1, "InfoFrame checksum");
        case (decoded_header[7:0])
          8'h84: begin
            assert (decoded_header[23:8] == 16'h0a01 && decoded_sub[0][15:8] == 1);
            packets_aif++; field_aif++;
          end
          8'h82: begin
            assert (decoded_header[23:8] == 16'h0d02 && decoded_sub[0][39:32] == 1);
            packets_avi++; field_avi++;
          end
          8'h83: begin
            assert (decoded_header[23:8] == 16'h1901 && decoded_sub[0][15:8] == "F");
            packets_spd++; field_spd++;
          end
          default: ;
        endcase
      end
      default: $fatal(1, "bad packet type %h", decoded_header);
    endcase
  endtask

  task automatic pixel_step(input int x, input int y);
    @(negedge clk_pix);
    px = '0;
    px.x = 12'(x); px.y = 12'(y);
    px.de = x < 640 && y < 480;
    px.hs = !(x >= 656 && x < 752);
    px.vs = !(y >= 490 && y < 492);
    px.sof = x == 0 && y == 0;
    px.r = 8'(x ^ y); px.g = 8'(x + y); px.b = 8'(x * 7 + y);
    #1;
    sampled = sample_ce;
    if (sampled) begin
      expected_samples.push_back(audio_valid ? {audio_l,audio_r} : 32'b0);
      sample_count++;
      if (last_sample_cycle != 0)
        assert (cycles-last_sample_cycle == 524 || cycles-last_sample_cycle == 525);
      last_sample_cycle = cycles;
    end
    @(posedge clk_pix);
    #1;
    cycles++;
    assert (!overflow) else $fatal(1, "audio overflow");
    if (px.de) begin
      for (int i = 0; i < 3; i++) assert (lane[i] == reference_video[i])
        else $fatal(1, "video altered/misaligned x=%0d lane=%0d",x,i);
    end else if (x >= 654 && x < 750) begin
      n0 = decode_terc(lane[0]); n1 = decode_terc(lane[1]); n2 = decode_terc(lane[2]);
      assert (n0[3] && n0[1:0] == {px.vs,px.hs});
      packet_pos = (x-654)%32;
      decoded_header[packet_pos] = n0[2];
      for (int i = 0; i < 4; i++) begin
        decoded_sub[i][2*packet_pos] = n1[i];
        decoded_sub[i][2*packet_pos+1] = n2[i];
      end
      if (packet_pos == 31) check_packet();
    end else if ((x >= 652 && x < 654) || (x >= 750 && x < 752)) begin
      assert (decode_terc(lane[0]) == {2'b11,px.vs,px.hs});
      assert (lane[1] == 10'b0100110011 && lane[2] == 10'b0100110011);
    end else if ((y < 479 || y == 524) && x >= 798) begin
      assert (lane[0] == 10'b1011001100 && lane[1] == 10'b0100110011 && lane[2] == 10'b1011001100);
    end else begin
      assert (lane[0] == control_code({px.vs,px.hs}));
      assert (lane[1] == control_code({1'b0,(x >= 644 && x < 652) ||
                                       ((y < 479 || y == 524) && x >= 790 && x < 798)}));
      assert (lane[2] == control_code({1'b0,x >= 644 && x < 652}));
    end
    if (sampled) begin audio_l = audio_l + 16'sd1; audio_r = audio_r - 16'sd1; end
  endtask

  initial begin
    px = '0;
    repeat (5) @(negedge clk_pix);
    rst_pix = 0;
    for (int frame = 0; frame < 3; frame++) begin
      field_aif = 0; field_avi = 0; field_spd = 0;
      for (int y = 0; y < 525; y++)
        for (int x = 0; x < 800; x++) pixel_step(x,y);
      assert (field_aif >= 1 && field_avi >= 1 && field_spd >= 1);
    end
    assert (sample_count == int'(longint'(cycles)*48000/25187500));
    assert (cycles > 10000 && packets_acr > 40 && cts_low > 10 && cts_high > 10);
    assert (received_samples > 2300 && sample_count-received_samples <= 7 && b_blocks > 10);
    assert (sum_cts / packets_acr >= 25187 && sum_cts / packets_acr <= 25188);
    // Switch/reset with old FIFO content, then muted samples. No old sample may escape.
    @(negedge clk_pix); rst_pix = 1; audio_valid = 0;
    repeat (5) @(negedge clk_pix);
    expected_samples.delete(); frame_index = 0; last_sample_cycle = 0;
    rst_pix = 0;
    for (int y = 0; y < 30; y++) for (int x = 0; x < 800; x++) pixel_step(x,y);
    $display("PASS HDMI: %0d cycles, %0d samples, %0d audio, CTS %0d/%0d, BCH/IEC/info/video/reset",
             cycles,sample_count,packets_audio,cts_low,cts_high);
    $finish;
  end
endmodule

// Simulation-only primitive; actual wrapper still instantiates existing production PHY.
module ODDR #(
    parameter string DDR_CLK_EDGE = "SAME_EDGE",
    parameter string SRTYPE = "SYNC"
) (
    output logic Q,
    input wire C, CE, D1, D2, R, S
);
  always @(C) begin
    if (R) Q = 0;
    else if (S) Q = 1;
    else if (CE) Q = C ? D1 : D2;
  end
endmodule
