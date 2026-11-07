// Source: nand2mario/snestang 5f0ef193145f67bded7f73f2c477ac8da4d85f7e, src/spc700/bcdadj.v
// Upstream project license: GPL-3.0 (see snes/LICENSE upstream copy).
import spc700::*;

module SPC700_BCDAdj(
    input wire [7:0] A,
    input wire ADD,
    input wire CI,
    input wire HI,
    output wire [7:0] R,
    output wire CO
);

reg [7:0] res;
reg tempC;

always @* begin : P1
    reg [7:0] temp0, temp1;

    temp0 = A;
    tempC = CI;
    temp1 = temp0;
    if(CI == ( ~ADD) || temp0 > 8'h99) begin
        if(ADD == 1'b0) begin
            temp1 = temp0 + 8'h60;
        end else begin
            temp1 = temp0 - 8'h60;
        end
        tempC =  ~ADD;
    end
    res = temp1;
    if(HI == ( ~ADD) || temp1[3:0] > 4'h9) begin
        if(ADD == 1'b0) begin
            res = temp1 + 8'h06;
        end else begin
            res = temp1 - 8'h06;
        end
    end
end

assign R = res;
assign CO = tempC;

endmodule
