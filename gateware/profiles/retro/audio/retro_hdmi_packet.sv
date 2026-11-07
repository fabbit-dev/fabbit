// SPDX-License-Identifier: MIT
// Adapted from hdl-util/hdmi packet_assembler.sv, Sameer Puri (2019).
// MIT license/provenance in this directory. Shift-register implementation avoids
// large per-pixel variable bit selectors; BCH polynomial and wire order unchanged.
`default_nettype none
module retro_hdmi_packet (
    input wire clk_pix,
    input wire rst_pix,
    input wire load,
    input wire island,
    input wire [23:0] header,
    input wire [55:0] sub [4],
    output wire [8:0] data_bits
);
  logic [23:0] header_shift = '0;
  logic [55:0] sub_shift [4];
  logic [7:0] parity [5];
  logic [4:0] position = '0;

  function automatic logic [7:0] ecc_bit(input logic [7:0] ecc, input logic value);
    return (ecc >> 1) ^ ((ecc[0] ^ value) ? 8'h83 : 8'h00);
  endfunction

  assign data_bits[0] = position < 24 ? header_shift[0] : parity[4][0];
  for (genvar i = 0; i < 4; i++) begin : g_sub
    assign data_bits[1+i] = position < 28 ? sub_shift[i][0] : parity[i][0];
    assign data_bits[5+i] = position < 28 ? sub_shift[i][1] : parity[i][1];
  end

  always_ff @(posedge clk_pix) begin
    if (rst_pix || load) begin
      position <= '0;
      header_shift <= rst_pix ? '0 : header;
      for (int i = 0; i < 4; i++) sub_shift[i] <= rst_pix ? '0 : sub[i];
      for (int i = 0; i < 5; i++) parity[i] <= '0;
    end else if (island) begin
      position <= position + 1'b1;
      header_shift <= header_shift >> 1;
      for (int i = 0; i < 4; i++) begin
        sub_shift[i] <= sub_shift[i] >> 2;
        if (position < 28)
          parity[i] <= ecc_bit(ecc_bit(parity[i], sub_shift[i][0]), sub_shift[i][1]);
        else parity[i] <= parity[i] >> 2;
      end
      if (position < 24) parity[4] <= ecc_bit(parity[4], header_shift[0]);
      else parity[4] <= parity[4] >> 1;
    end
  end
endmodule
