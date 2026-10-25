`default_nettype none

// One-bit 640x480 plane: 10 RAMB36, beside the 64-RAMB36 capture store.
// 44 RECT: addr={y[11:0],x[11:0]}, x/w multiples of 8, BE16 w/h, MSB-first pixels.
// 43 CTRL: exact four-byte FBKY key; addr[0] enables. Black until enabled.
module la_plane
  import video_pkg::*;
(
    input wire clk,
    input wire rst,
    input wire header,
    input wire [7:0] command,
    input wire [23:0] address,
    input wire write_valid,
    input wire [7:0] data,
    input wire frame_end,
    output logic shown = 1'b0,
    input wire clk_pix,
    input vpx_t px_in,
    output vpx_t px_out
);
  logic [7:0] cmd = 0;
  logic [2:0] n = 0;
  logic [11:0] x0 = 0, y0 = 0;
  logic [15:0] width = 0, height = 0;
  logic [16:0] x = 0, y = 0;
  logic [31:0] key = 0;
  logic on = 0;
  logic we = 0;
  logic [15:0] waddr = 0;
  logic [7:0] wdata = 0;
  always_ff @(posedge clk) begin
    we <= 1'b0;
    if (header) begin
      cmd <= command;
      n <= 0;
      x0 <= address[11:0];
      y0 <= address[23:12];
      on <= address[0];
      key <= 0;
    end
    if (write_valid) begin
      if (n != 7) n <= n + 1'b1;
      if (cmd == 8'h43) key <= {key[23:0], data};
      if (cmd == 8'h44) begin
        case (n)
          0: width[15:8] <= data;
          1: width[7:0] <= data;
          2: height[15:8] <= data;
          3: begin
            height[7:0] <= data;
            x <= {5'd0, x0};
            y <= {5'd0, y0};
          end
          default: if (width != 0 && width[2:0] == 0 && x0[2:0] == 0 &&
                       y < {5'd0, y0} + {1'b0, height}) begin
            we <= x < 640 && y < 480;
            waddr <= 16'((y << 6) + (y << 4) + (x >> 3));
            wdata <= data;
            if (x + 17'd8 >= {5'd0, x0} + {1'b0, width}) begin
              x <= {5'd0, x0};
              y <= y + 1'b1;
            end else x <= x + 17'd8;
          end
        endcase
      end
    end
    if (frame_end) begin
      if (cmd == 8'h43 && n == 4 && key == "FBKY") shown <= on;
      cmd <= 0;
    end
    if (rst) begin
      shown <= 1'b0;
      cmd <= 0;
      n <= 0;
      we <= 1'b0;
    end
  end

  wire [15:0] raddr = (16'(px_in.y) << 6) + (16'(px_in.y) << 4) +
                      (16'(px_in.x) >> 3);
  // Explicit 4 KiB banks avoid Vivado rounding the complete dual-clock array to 64 KiB.
  wire [7:0] bank_data [10];
  for (genvar bank = 0; bank < 10; bank++) begin : g_bank
    ram_sdp #(.Width(8), .Depth(4096)) u_mem (
        .wclk(clk), .we(we && waddr[15:12] == 4'(bank)),
        .waddr(waddr[11:0]), .wdata(wdata),
        .rclk(clk_pix), .re(px_in.de && raddr[15:12] == 4'(bank)),
        .raddr(raddr[11:0]), .rdata(bank_data[bank]));
  end
  logic [3:0] read_bank = 0;
  always_ff @(posedge clk_pix) read_bank <= raddr[15:12];
  wire [7:0] rdata = (read_bank < 10) ? bank_data[read_bank] : 8'd0;
  wire show_pix;
  sync_bit u_show (.clk(clk_pix), .d(shown), .q(show_pix));
  vpx_t p1;
  always_ff @(posedge clk_pix) begin
    p1 <= px_in;
    px_out <= vpx_rgb(p1, {8{show_pix && p1.de && rdata[3'd7-p1.x[2:0]]}},
                         {8{show_pix && p1.de && rdata[3'd7-p1.x[2:0]]}},
                         {8{show_pix && p1.de && rdata[3'd7-p1.x[2:0]]}});
  end
endmodule
