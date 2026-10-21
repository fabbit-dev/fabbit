`default_nettype none

// Логический анализатор: после arm ждёт спада CS# и пишет Depth выборок probe на каждом такте clk.
// Затем выгружает в UART строку "L" + Depth*2 hex-символов + "\n".
module la_capture #(
    parameter int Depth = 4096,
    parameter int Div = 868
) (
    input  wire       clk,
    input  wire       arm,
    input  wire [7:0] probe,  // бит 1 = CS#
    output wire       busy,   // захват или выгрузка: UART занят
    output wire       tx
);
  logic [7:0] mem[Depth];
  logic [11:0] wa = 12'd0, ra = 12'd0;
  logic [7:0] rdat;
  logic [7:0] p1 = 8'hFF, p2 = 8'hFF;

  typedef enum logic [2:0] {
    Idle,
    Armed,
    Cap,
    Head,
    HexHi,
    HexLo,
    Tail
  } state_e;
  state_e state = Idle;
  assign busy = (state != Idle) && (state != Armed);

  logic u_start = 1'b0, u_busy;
  logic [7:0] u_data = 8'd0;
  uart_tx #(
      .Div(Div)
  ) u_tx (
      .clk  (clk),
      .start(u_start),
      .data (u_data),
      .busy (u_busy),
      .tx   (tx)
  );

  function automatic logic [7:0] hex(input logic [3:0] n);
    hex = (n < 4'd10) ? (8'd48 + {4'd0, n}) : (8'd55 + {4'd0, n});
  endfunction

  always_ff @(posedge clk) begin
    p1 <= probe;
    p2 <= p1;
    if (state == Cap) mem[wa] <= p2;
    rdat <= mem[ra];
  end

  logic wait_u = 1'b0;
  always_ff @(posedge clk) begin
    u_start <= 1'b0;
    unique case (state)
      Idle: if (arm) state <= Armed;
      Armed: begin
        wa <= 12'd0;
        if (p2[1] && !p1[1]) state <= Cap;  // спад CS#
      end
      Cap: begin
        wa <= wa + 12'd1;
        if (wa == 12'(Depth - 1)) begin
          ra    <= 12'd0;
          state <= Head;
        end
      end
      Head:
      if (!u_busy && !u_start) begin
        u_data  <= "L";
        u_start <= 1'b1;
        state   <= HexHi;
      end
      HexHi:
      if (!u_busy && !u_start) begin
        u_data  <= hex(rdat[7:4]);
        u_start <= 1'b1;
        state   <= HexLo;
      end
      HexLo:
      if (!u_busy && !u_start) begin
        u_data  <= hex(rdat[3:0]);
        u_start <= 1'b1;
        if (ra == 12'(Depth - 1)) state <= Tail;
        else begin
          ra    <= ra + 12'd1;
          state <= HexHi;
        end
      end
      Tail:
      if (!u_busy && !u_start) begin
        u_data  <= 8'h0A;
        u_start <= 1'b1;
        state   <= Idle;
      end
      default: state <= Idle;
    endcase
  end
endmodule
