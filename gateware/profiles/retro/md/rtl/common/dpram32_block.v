// Modified for Fabbit on 2026-10-25; original notices retained below.
// Fabbit: portable synchronous RAM; upstream simulation semantics retained.
// Gowin 32-bit dual-port RAM backed by 2 BSRAM blocks (max 4KB), with byte-enable support
module retro_md_dpram32_block(
    
    input               clka,
    input       [9:0]   addr_a,         // word address
    input       [31:0]  datain_a,
    output reg  [31:0]  dataout_a,
    input               we_a,
    input       [3:0]   be_a,           // byte-enable
    
    input               clkb,
    input       [9:0]   addr_b,
    input       [31:0]  datain_b,
    output reg  [31:0]  dataout_b,
    input               we_b,
    input       [3:0]   be_b
);


// Separate byte arrays make byte writes inferable on Xilinx TDP BRAM.
// Outputs hold while the respective whole-port write enable is asserted.
for (genvar lane = 0; lane < 4; lane = lane + 1) begin : g_byte
    reg [7:0] ram [0:1023];
    always @(posedge clka) begin
        if (we_a && be_a[lane]) ram[addr_a] <= datain_a[8*lane +: 8];
        if (!we_a) dataout_a[8*lane +: 8] <= ram[addr_a];
    end
    always @(posedge clkb) begin
        if (we_b && be_b[lane]) ram[addr_b] <= datain_b[8*lane +: 8];
        if (!we_b) dataout_b[8*lane +: 8] <= ram[addr_b];
    end
end
endmodule
