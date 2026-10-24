`default_nettype none

// Палитра 2C02 (nesdev.org/wiki/PPU_palettes, значения из nes2hdmi.sv NESTang) и усиление
// (emphasis): невыбранные каналы темнеют до 3/4. Общая для видеотракта профиля и тестов.
package nes_palette_pkg;
  localparam logic [23:0] Pal[64] = '{
    24'h545454, 24'h001e74, 24'h081090, 24'h300088, 24'h440064, 24'h5c0030, 24'h540400, 24'h3c1800,
    24'h202a00, 24'h083a00, 24'h004000, 24'h003c00, 24'h00323c, 24'h000000, 24'h000000, 24'h000000,
    24'h989698, 24'h084cc4, 24'h3032ec, 24'h5c1ee4, 24'h8814b0, 24'ha01464, 24'h982220, 24'h783c00,
    24'h545a00, 24'h287200, 24'h087c00, 24'h007628, 24'h006678, 24'h000000, 24'h000000, 24'h000000,
    24'heceeec, 24'h4c9aec, 24'h787cec, 24'hb062ec, 24'he454ec, 24'hec58b4, 24'hec6a64, 24'hd48820,
    24'ha0aa00, 24'h74c400, 24'h4cd020, 24'h38cc6c, 24'h38b4cc, 24'h3c3c3c, 24'h000000, 24'h000000,
    24'heceeec, 24'ha8ccec, 24'hbcbcec, 24'hd4b2ec, 24'hecaeec, 24'hecaed4, 24'hecb4b0, 24'he4c490,
    24'hccd278, 24'hb4de78, 24'ha8e290, 24'h98e2b4, 24'ha0d6e4, 24'ha0a2a0, 24'h000000, 24'h000000
  };

  function automatic logic [7:0] dim(input logic [7:0] c, input logic on);
    return on ? c - (c >> 2) : c;
  endfunction

  // {emphasis[2:0] (бит 0 красный, 1 зелёный, 2 синий; регистр $2001), color[5:0]} → RGB
  function automatic logic [23:0] nes_rgb(input logic [8:0] idx);
    logic [23:0] c;
    logic [2:0] e;
    c = Pal[idx[5:0]];
    e = idx[8:6];
    if (e == 3'd0) return c;
    return {dim(c[23:16], !e[0]), dim(c[15:8], !e[1]), dim(c[7:0], !e[2])};
  endfunction

endpackage
