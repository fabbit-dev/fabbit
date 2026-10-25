`default_nettype none
`timescale 1ns / 1ps
module tb_retro_pad;
  logic [15:0] pad = '0;
  wire [11:0] md, snes;
  retro_pad dut (.*);
  initial begin
    #1;
    assert (md == 0 && snes == 0) else $fatal(1, "idle");
    for (int i = 0; i < 16; i++) begin
      pad = 16'h0001 << i;
      #1;
      case (i)
        0: assert (md == 12'h001 && snes == 12'h010) else $fatal(1, "up");
        1: assert (md == 12'h002 && snes == 12'h020) else $fatal(1, "down");
        2: assert (md == 12'h004 && snes == 12'h040) else $fatal(1, "left");
        3: assert (md == 12'h008 && snes == 12'h080) else $fatal(1, "right");
        4: assert (md == 12'h010 && snes == 12'h100) else $fatal(1, "A/F2");
        5: assert (md == 12'h020 && snes == 12'h001) else $fatal(1, "B/F3");
        6: assert (md == 12'h040 && snes == 12'h200) else $fatal(1, "X/F1");
        7: assert (md == 12'h080 && snes == 12'h002) else $fatal(1, "Y/F4");
        8: assert (md == 12'h100 && snes == 12'h400) else $fatal(1, "L1");
        9: assert (md == 12'h200 && snes == 12'h800) else $fatal(1, "R1");
        14: assert (md == 12'h400 && snes == 12'h004) else $fatal(1, "select");
        15: assert (md == 12'h800 && snes == 12'h008) else $fatal(1, "start");
        default: assert (md == 0 && snes == 0) else $fatal(1, "reserved");
      endcase
    end
    pad = 16'h000F;
    #1;
    assert (md == 0 && snes == 0) else $fatal(1, "opposite directions");
    $display("ok retro pad: existing PAD16, MD 3-button, SNES ABXY/Start/Select, Fn reserved");
    $finish;
  end
endmodule
