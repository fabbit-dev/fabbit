`default_nettype none

// Печать строки "<tag> XXXXXXXX\r\n" (12 символов) через uart_tx.
module uart_hexline #(
    parameter int Div = 217
) (
    input  wire        clk,
    input  wire        start,
    input  wire [ 7:0] tag,
    input  wire [31:0] value,
    output wire        busy,
    output wire        tx
);
  logic [ 3:0] idx = 4'd0;
  logic        run = 1'b0;
  logic [ 7:0] tag_r = 8'd0;
  logic [31:0] val_r = 32'd0;
  logic        u_start = 1'b0;
  logic        u_busy;
  logic [ 7:0] ch;
  assign busy = run;

  function automatic logic [7:0] hex(input logic [3:0] n);
    hex = (n < 4'd10) ? (8'd48 + {4'd0, n}) : (8'd55 + {4'd0, n});
  endfunction

  always_comb begin
    unique case (idx)
      4'd0: ch = tag_r;
      4'd1: ch = " ";
      4'd2: ch = hex(val_r[31:28]);
      4'd3: ch = hex(val_r[27:24]);
      4'd4: ch = hex(val_r[23:20]);
      4'd5: ch = hex(val_r[19:16]);
      4'd6: ch = hex(val_r[15:12]);
      4'd7: ch = hex(val_r[11:8]);
      4'd8: ch = hex(val_r[7:4]);
      4'd9: ch = hex(val_r[3:0]);
      4'd10: ch = 8'h0D;
      default: ch = 8'h0A;
    endcase
  end

  uart_tx #(
      .Div(Div)
  ) u_tx (
      .clk  (clk),
      .start(u_start),
      .data (ch),
      .busy (u_busy),
      .tx   (tx)
  );

  // u_start защёлкивает ch для текущего idx, idx растёт на следующем такте
  always_ff @(posedge clk) begin
    u_start <= 1'b0;
    if (!run) begin
      if (start) begin
        run   <= 1'b1;
        idx   <= 4'd0;
        tag_r <= tag;
        val_r <= value;
      end
    end else if (u_start) begin
      idx <= idx + 4'd1;
    end else if (!u_busy) begin
      if (idx == 4'd12) run <= 1'b0;
      else u_start <= 1'b1;
    end
  end
endmodule
