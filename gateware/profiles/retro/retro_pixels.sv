`default_nettype none

// Native CE/DE/sync -> pixel writes for a later shared presentation buffer.
// No clocks muxed here. Instantiate in EACH source domain, then cross via a FIFO
// or memory. Pixel positions count active samples, line position advances at the
// next active line after a witnessed HS pulse, not on an arbitrary blanking edge.
// Active-low syncs; normalise SNES polarity at the call site. Supports progressive
// up to 512x240; unsupported/interlace suppress writes, do not reinterpret fields.
// Configuration remains stable for a frame; reset after changing source/mode.
module retro_pixels (
    input  wire        clk,
    input  wire        rst,
    input  wire        active,
    input  wire        pixel_ce,
    input  wire        hs_n,
    input  wire        vs_n,
    input  wire        hde,
    input  wire        vde,
    input  wire        unsupported,
    input  wire [14:0] rgb,
    output logic       we = 1'b0,
    output logic [8:0] x = '0,
    output logic [7:0] y = '0,
    output logic [14:0] data = '0,
    output logic       frame = 1'b0,
    output logic       overflow = 1'b0
);
  logic [9:0] column = '0;
  logic [8:0] row = '0;
  logic hs_old = 1'b1, vs_old = 1'b1;
  logic line_pending = 1'b0, seen_line = 1'b0;
  always_ff @(posedge clk) begin
    we <= 1'b0;
    frame <= 1'b0;
    hs_old <= hs_n;
    vs_old <= vs_n;
    if (rst || !active) begin
      column <= '0;
      row <= '0;
      line_pending <= 1'b0;
      seen_line <= 1'b0;
      overflow <= 1'b0;
    end else if (vs_old && !vs_n) begin
      column <= '0;
      row <= '0;
      line_pending <= 1'b0;
      seen_line <= 1'b0;
      overflow <= 1'b0;
      frame <= 1'b1;
    end else begin
      if (hs_old && !hs_n) begin
        column <= '0;
        line_pending <= 1'b1;
      end
      if (pixel_ce && hde && vde && hs_n && vs_n) begin
        if (line_pending) begin
          line_pending <= 1'b0;
          if (seen_line && row != 9'h1FF) row <= row + 1'b1;
          seen_line <= 1'b1;
        end
        if (column != 10'h3FF) column <= column + 1'b1;
        if (column >= 512 || (line_pending && seen_line ? row + 9'd1 : row) >= 240)
          overflow <= 1'b1;
        else if (!unsupported && !overflow) begin
          we <= 1'b1;
          x <= column[8:0];
          y <= 8'(line_pending && seen_line ? row + 9'd1 : row);
          data <= rgb;
        end
      end
    end
  end
endmodule
