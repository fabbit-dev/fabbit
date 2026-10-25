`default_nettype none

// UART TX 8N1. Div = f_clk / baud.
module uart_tx #(
    parameter int Div = 217
) (
    input  wire       clk,
    input  wire       start,
    input  wire [7:0] data,
    output wire       busy,
    output wire       tx
);
  logic [ 9:0] sh = 10'h3FF;
  logic [ 3:0] nbits = 4'd0;
  logic [15:0] cnt = 16'd0;
  assign tx   = sh[0];
  assign busy = (nbits != 0);

  always_ff @(posedge clk) begin
    if (nbits != 0) begin
      if (cnt == Div - 1) begin
        cnt   <= 16'd0;
        sh    <= {1'b1, sh[9:1]};
        nbits <= nbits - 4'd1;
      end else cnt <= cnt + 16'd1;
    end else if (start) begin
      sh    <= {1'b1, data, 1'b0};
      nbits <= 4'd10;
      cnt   <= 16'd0;
    end
  end
endmodule
