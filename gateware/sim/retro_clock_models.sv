`timescale 1ns/1ps
// verilog_lint: waive-start module-filename
// Simulation-only ideal primitives. Real product uses Xilinx primitives.
module BUFG(input wire I,output wire O);assign O=I;endmodule
module BUFH(input wire I,output wire O);assign O=I;endmodule
module BUFGCE #(parameter string SIM_DEVICE="7SERIES")
    (input wire I,CE,output wire O);
  logic en=1;always @(negedge I) en<=CE;assign O=I && en;
endmodule
module BUFGCTRL #(parameter string SIM_DEVICE="7SERIES")
    (input wire I0,I1,S0,S1,CE0,CE1,IGNORE0,IGNORE1,output wire O);
  logic e0=0,e1=0;
  always @(negedge I0) e0<=S0 && CE0 && !e1;
  always @(negedge I1) e1<=S1 && CE1 && !e0;
  assign O=(I0 && e0)||(I1 && e1);
endmodule
module IOBUF(input wire I,T,inout wire IO,output wire O);
  assign IO=T ? 1'bz : I;assign O=IO;
endmodule
module PLLE2_BASE #(parameter real CLKIN1_PERIOD=40.0,
    parameter int DIVCLK_DIVIDE=1,parameter int CLKFBOUT_MULT=40,
    parameter int CLKOUT0_DIVIDE=10)
    (input wire CLKIN1,CLKFBIN,PWRDWN,RST,output wire CLKFBOUT,
     output logic CLKOUT0=0,output wire CLKOUT1,CLKOUT2,CLKOUT3,CLKOUT4,CLKOUT5,
     output logic LOCKED=0);
  localparam realtime Half=CLKIN1_PERIOD*DIVCLK_DIVIDE*CLKOUT0_DIVIDE/CLKFBOUT_MULT/2;
  always #(Half) CLKOUT0=~CLKOUT0;
  assign CLKFBOUT=CLKIN1;
  assign {CLKOUT1,CLKOUT2,CLKOUT3,CLKOUT4,CLKOUT5}=0;
  initial begin #1us;LOCKED=1;end
endmodule
module MMCME2_ADV #(
    parameter real CLKIN1_PERIOD=40.0,parameter real CLKFBOUT_MULT_F=36.0,
    parameter real CLKOUT0_DIVIDE_F=42.0,
    parameter int DIVCLK_DIVIDE=1,parameter int CLKOUT1_DIVIDE=14,
    parameter int CLKOUT2_DIVIDE=14,parameter int CLKOUT3_DIVIDE=1,
    parameter real CLKOUT2_PHASE=0.0,parameter real CLKOUT3_PHASE=0.0,
    parameter string BANDWIDTH="OPTIMIZED",parameter string CLKOUT2_USE_FINE_PS="FALSE",
    parameter string COMPENSATION="ZHOLD"
) (input wire CLKIN1,CLKIN2,CLKINSEL,CLKFBIN,PWRDWN,RST,PSCLK,PSEN,PSINCDEC,
   input wire [6:0] DADDR,input wire DCLK,DEN,input wire [15:0] DI,input wire DWE,
   output wire CLKFBOUT,CLKFBOUTB,
   output logic CLKOUT0=1,CLKOUT1=1,CLKOUT2=1,CLKOUT3=1,
   output wire CLKOUT0B,CLKOUT1B,CLKOUT2B,CLKOUT3B,CLKOUT4,CLKOUT5,CLKOUT6,
   output logic LOCKED=0,output wire PSDONE,output wire [15:0] DO,
   output wire DRDY,CLKINSTOPPED,CLKFBSTOPPED);
  localparam realtime Vco=CLKIN1_PERIOD*DIVCLK_DIVIDE/CLKFBOUT_MULT_F;
  always #(Vco*CLKOUT0_DIVIDE_F/2) CLKOUT0=~CLKOUT0;
  always #(Vco*CLKOUT1_DIVIDE/2) CLKOUT1=~CLKOUT1;
  initial begin
    #(Vco*CLKOUT2_DIVIDE*CLKOUT2_PHASE/360.0);
    forever #(Vco*CLKOUT2_DIVIDE/2) CLKOUT2=~CLKOUT2;
  end
  initial begin
    #(Vco*CLKOUT3_DIVIDE*CLKOUT3_PHASE/360.0);
    forever #(Vco*CLKOUT3_DIVIDE/2) CLKOUT3=~CLKOUT3;
  end
  assign CLKFBOUT=CLKIN1;assign CLKFBOUTB=~CLKIN1;
  assign {CLKOUT0B,CLKOUT1B,CLKOUT2B,CLKOUT3B}={~CLKOUT0,~CLKOUT1,~CLKOUT2,~CLKOUT3};
  assign {CLKOUT4,CLKOUT5,CLKOUT6,PSDONE,DO,DRDY,CLKINSTOPPED,CLKFBSTOPPED}=0;
  initial begin #1us;LOCKED=1;end
endmodule
module MMCME2_BASE #(
    parameter real CLKIN1_PERIOD=40.0,parameter real CLKFBOUT_MULT_F=50.375,
    parameter real CLKOUT0_DIVIDE_F=25.0,
    parameter int DIVCLK_DIVIDE=2,parameter int CLKOUT1_DIVIDE=5
) (input wire CLKIN1,CLKFBIN,RST,PWRDWN,output wire CLKFBOUT,CLKFBOUTB,
   output logic CLKOUT0=0,CLKOUT1=0,output wire CLKOUT0B,CLKOUT1B,CLKOUT2,CLKOUT2B,
   CLKOUT3,CLKOUT3B,CLKOUT4,CLKOUT5,CLKOUT6,output logic LOCKED=0);
  localparam realtime Vco=CLKIN1_PERIOD*DIVCLK_DIVIDE/CLKFBOUT_MULT_F;
  always #(Vco*CLKOUT0_DIVIDE_F/2) CLKOUT0=~CLKOUT0;
  always #(Vco*CLKOUT1_DIVIDE/2) CLKOUT1=~CLKOUT1;
  assign CLKFBOUT=CLKIN1;assign CLKFBOUTB=~CLKIN1;
  assign CLKOUT0B=~CLKOUT0;assign CLKOUT1B=~CLKOUT1;
  assign {CLKOUT2,CLKOUT2B,CLKOUT3,CLKOUT3B,CLKOUT4,CLKOUT5,CLKOUT6}=0;
  initial begin #1us;LOCKED=1;end
endmodule
