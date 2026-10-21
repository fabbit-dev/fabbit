`default_nettype none

// Простая двухпортовая память с двумя тактами: запись в домене wclk, чтение в домене rclk,
// чтение регистровое (задержка 1 такт rclk). Шаблон UG901 «Simple Dual-Port Block RAM with Dual
// Clocks»: Vivado и yosys (synth_xilinx) кладут её в RAMB18/RAMB36, а не в LUTRAM.
// Содержимое при включении не задано; Style = "block" | "distributed".
module ram_sdp #(
    parameter int    Width = 8,
    parameter int    Depth = 1024,
    parameter string Style = "block",
    localparam int   Aw = $clog2(Depth)
) (
    input  wire              wclk,
    input  wire              we,
    input  wire  [Aw-1:0]    waddr,
    input  wire  [Width-1:0] wdata,
    input  wire              rclk,
    input  wire              re,
    input  wire  [Aw-1:0]    raddr,
    output logic [Width-1:0] rdata
);
  (* ram_style = Style *) logic [Width-1:0] mem [Depth];

  always_ff @(posedge wclk)
    if (we) mem[waddr] <= wdata;

  always_ff @(posedge rclk)
    if (re) rdata <= mem[raddr];

endmodule
