// Modified for Fabbit on 2026-10-25; original notices retained below.
// Fabbit: portable synchronous RAM; upstream simulation semantics retained.
// Gowin dual-port RAM backed by a single BSRAM block (max 2KB)
module retro_md_dpram_block(clka, clkb, addr_a, datain_a, dataout_a, we_a, addr_b, datain_b, dataout_b, we_b);
    parameter                   ADDR_WIDTH = 6;
    parameter                   DATA_WIDTH = 8;     // 4,8,16
    
    input                       clka;
    input  [ADDR_WIDTH-1:0]     addr_a;
    input  [DATA_WIDTH-1:0]     datain_a;
    output reg [DATA_WIDTH-1:0]     dataout_a;
    input                       we_a;
    
    input                       clkb;
    input  [ADDR_WIDTH-1:0]     addr_b;
    input  [DATA_WIDTH-1:0]     datain_b;
    output reg [DATA_WIDTH-1:0]     dataout_b;
    input                       we_b;

if (DATA_WIDTH != 4 && DATA_WIDTH != 8 && DATA_WIDTH != 16)
    $error("ERROR: DATA_WIDTH must be 4, 8, or 16");
if (ADDR_WIDTH > 12)
    $error("ERROR: ADDR_WIDTH must be <= 12");


reg [DATA_WIDTH-1:0]    ram[0:2**ADDR_WIDTH-1] /* verilator public */;

always @(posedge clka) begin
    // Port A
    if (we_a == 1'b1)
        ram[addr_a] <= datain_a;
    else 
        dataout_a <= ram[addr_a];
end
        
always @(posedge clkb) begin
    // Port B
    if (we_b == 1'b1)
        ram[addr_b] <= datain_b;
    else 
        dataout_b <= ram[addr_b];
end 

    
endmodule

