`default_nettype none
`timescale 1ns / 1ps

// Заглушки примитивов Xilinx для iverilog. ICAPE2 запоминает последнюю IPROG и WBSTAR.
module ICAPE2 #(
    parameter string ICAP_WIDTH = "X32"
) (
    input  wire        CLK,
    input  wire        CSIB,
    input  wire        RDWRB,
    input  wire [31:0] I,
    output logic [31:0] O
);
  function automatic logic [31:0] sw(input logic [31:0] w);
    sw = {w[24], w[25], w[26], w[27], w[28], w[29], w[30], w[31],
          w[16], w[17], w[18], w[19], w[20], w[21], w[22], w[23],
          w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15],
          w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7]};
  endfunction
  logic [31:0] prev = 0;
  logic [31:0] wbstar = 0;
  logic        iprog = 0;
  initial O = sw(32'h0000_0001);  // BOOTSTS: VALID_0
  always @(posedge CLK)
    if (!CSIB && !RDWRB) begin
      if (prev == 32'h3002_0001) wbstar <= sw(I);
      if (prev == 32'h3000_8001 && sw(I) == 32'h0000_000F) iprog <= 1;
      prev <= sw(I);
    end
endmodule

module STARTUPE2 #(
    parameter string PROG_USR = "FALSE",
    parameter real   SIM_CCLK_FREQ = 0.0
) (
    output wire CFGCLK,
    output wire CFGMCLK,
    output wire EOS,
    output wire PREQ,
    input  wire CLK,
    input  wire GSR,
    input  wire GTS,
    input  wire KEYCLEARB,
    input  wire PACK,
    input  wire USRCCLKO,
    input  wire USRCCLKTS,
    input  wire USRDONEO,
    input  wire USRDONETS
);
  assign CFGCLK = 0;
  assign CFGMCLK = 0;
  assign EOS = 1;
  assign PREQ = 0;
endmodule
