// Source: nand2mario/snestang 5f0ef193145f67bded7f73f2c477ac8da4d85f7e, src/65C816/bit_adder.v
// Upstream project license: GPL-3.0 (see snes/LICENSE upstream copy).

module bit_adder(A, B, CI, S, CO);
   input   A;
   input   B;
   input   CI;
   output  S;
   output  CO;
   assign S = ((~A) & (~B) & CI) | ((~A) & B & (~CI)) | (A & (~B) & (~CI)) | (A & B & CI);
   assign CO = ((~A) & B & CI) | (A & (~B) & CI) | (A & B & (~CI)) | (A & B & CI);

endmodule
