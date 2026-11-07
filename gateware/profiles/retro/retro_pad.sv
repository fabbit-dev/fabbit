`default_nettype none

// Fabbit RetroPad16 -> console wrappers' native pad words. Wire protocol is
// Up Down Left Right A B X Y L1 R1 L2 R2 L3 R3 Select Start, bits 0..15.
// Generic MD mapping: Up Down Left Right A B X Y L R Select Start.
// SNES serial word: B Y Select Start Up Down Left Right A X L R.
// Same NES convention: F2=A, F3=B, F1=turbo A, F4=turbo B, Menu=Start,
// Back=Select. MD uses F4 for A/Y, F3 for B, F2 for C/A; no turbo here.
// SNES F1=X, F2=A, F3=B, F4=Y. L1/R1 forward when supplied by an external
// pad; physical stand has no L/R pair. Fn stays a supervisor exit chord.
module retro_pad (
    input  wire [15:0] pad,
    output wire [11:0] md,
    output wire [11:0] snes
);
  wire up = pad[0] && !pad[1];
  wire down = pad[1] && !pad[0];
  wire left = pad[2] && !pad[3];
  wire right = pad[3] && !pad[2];
  assign md = {pad[15], pad[14], pad[9:8], pad[7], pad[6], pad[5], pad[4],
               right, left, down, up};
  assign snes = {pad[9:8], pad[6], pad[4], right, left, down, up, pad[15], pad[14],
                 pad[7], pad[5]};
endmodule
