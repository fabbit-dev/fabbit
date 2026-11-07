// Пустые объявления примитивов Xilinx для фронтенда yosys-slang (read_slang --empty-blackboxes):
// slang проверяет имена параметров и портов, synth_xilinx затем ставит настоящие ячейки.
// Добавлять сюда примитив, когда он впервые нужен в коде под slang.
// verilog_lint: waive-start module-filename
module BUFG (output wire O, input wire I);
endmodule

// Declaration only; behavioral tests bind the vendor UNISIM implementation.
module IDDR #(
    parameter string DDR_CLK_EDGE = "OPPOSITE_EDGE",
    parameter bit INIT_Q1 = 1'b0,
    parameter bit INIT_Q2 = 1'b0,
    parameter string SRTYPE = "SYNC"
) (
    output wire Q1, Q2,
    input wire C, CE, D, R, S
);
endmodule

module ISERDESE2 #(
    parameter string DATA_RATE = "DDR",
    parameter int DATA_WIDTH = 4,
    parameter string INTERFACE_TYPE = "NETWORKING",
    parameter string IOBDELAY = "NONE",
    parameter int NUM_CE = 1,
    parameter string SERDES_MODE = "MASTER"
) (
    output wire O, Q1, Q2, Q3, Q4, Q5, Q6, Q7, Q8, SHIFTOUT1, SHIFTOUT2,
    input wire BITSLIP, CE1, CE2, CLK, CLKB, CLKDIV, CLKDIVP, D, DDLY,
               DYNCLKDIVSEL, DYNCLKSEL, OCLK, OCLKB, OFB, RST, SHIFTIN1, SHIFTIN2
);
endmodule

module ODDR #(
    parameter string DDR_CLK_EDGE = "OPPOSITE_EDGE",
    parameter bit INIT = 1'b0,
    parameter string SRTYPE = "SYNC"
) (
    output wire Q,
    input  wire C, CE, D1, D2, R, S
);
endmodule

module MMCME2_BASE #(
    parameter string BANDWIDTH = "OPTIMIZED",
    parameter int CLKFBOUT_MULT_F = 5,
    parameter int CLKIN1_PERIOD = 0,
    parameter int CLKOUT0_DIVIDE_F = 1,
    parameter int CLKOUT1_DIVIDE = 1,
    parameter int CLKOUT2_DIVIDE = 1,
    parameter int CLKOUT3_DIVIDE = 1,
    parameter int CLKOUT4_DIVIDE = 1,
    parameter int CLKOUT5_DIVIDE = 1,
    parameter int CLKOUT6_DIVIDE = 1,
    parameter string CLKOUT4_CASCADE = "FALSE",
    parameter int DIVCLK_DIVIDE = 1,
    parameter string STARTUP_WAIT = "FALSE"
) (
    output wire CLKFBOUT, CLKFBOUTB,
    output wire CLKOUT0, CLKOUT0B, CLKOUT1, CLKOUT1B, CLKOUT2, CLKOUT2B, CLKOUT3, CLKOUT3B,
    output wire CLKOUT4, CLKOUT5, CLKOUT6, LOCKED,
    input  wire CLKFBIN, CLKIN1, PWRDWN, RST
);
endmodule
// verilog_lint: waive-stop module-filename
