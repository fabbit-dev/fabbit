`default_nettype none

// Keep tri-state buffers only at the physical boundary. Controllers expose split
// input/output/enable signals so that arbitration cannot create internal tri-state
// logic or multiple independently driven DQ buses. Clock forwarding lives in top.
module retro_sdram_io (
    input  wire [31:0] dq_out,
    input  wire        dq_oe,
    output wire [31:0] dq_in,
    inout  wire [31:0] sd_dq
);
  assign sd_dq = dq_oe ? dq_out : {32{1'bz}};
  assign dq_in = sd_dq;
endmodule
