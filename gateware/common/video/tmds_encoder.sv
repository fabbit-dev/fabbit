`default_nettype none

// Кодер TMDS одной линии (DVI 1.0, §3.2.2): 8 бит видео или 2 бита управления → 10 бит.
// Задержка 1 такт. Баланс постоянной составляющей держит счётчик cnt.
module tmds_encoder (
    input  wire        clk,
    input  wire        ce,
    input  wire  [7:0] d,
    input  wire  [1:0] c,   // управление в гашении: {vs, hs} на линии 0, иначе 0
    input  wire        de,
    output logic [9:0] q
);
  function automatic logic [3:0] ones(input logic [7:0] x);
    logic [3:0] s;
    s = '0;
    for (int i = 0; i < 8; i++) s += {3'b0, x[i]};
    return s;
  endfunction

  logic [3:0] n1d, n1q;
  logic [8:0] qm;
  logic signed [5:0] cnt = '0, diff;  // diff = единицы − нули в qm[7:0]

  always_comb begin
    n1d   = ones(d);
    qm[0] = d[0];
    if (n1d > 4 || (n1d == 4 && !d[0])) begin
      for (int i = 1; i < 8; i++) qm[i] = qm[i-1] ~^ d[i];
      qm[8] = 1'b0;
    end else begin
      for (int i = 1; i < 8; i++) qm[i] = qm[i-1] ^ d[i];
      qm[8] = 1'b1;
    end
    n1q  = ones(qm[7:0]);
    diff = $signed({1'b0, n1q, 1'b0}) - 6'sd8;
  end

  always_ff @(posedge clk)
    if (ce) begin
      if (!de) begin
        cnt <= '0;
        case (c)
          2'b00:   q <= 10'b1101010100;
          2'b01:   q <= 10'b0010101011;
          2'b10:   q <= 10'b0101010100;
          default: q <= 10'b1010101011;
        endcase
      end else if (cnt == 0 || diff == 0) begin
        q   <= {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
        cnt <= qm[8] ? cnt + diff : cnt - diff;
      end else if ((cnt > 0) == (diff > 0)) begin
        q   <= {1'b1, qm[8], ~qm[7:0]};
        cnt <= cnt + (qm[8] ? 6'sd2 : 6'sd0) - diff;
      end else begin
        q   <= {1'b0, qm[8], qm[7:0]};
        cnt <= cnt - (qm[8] ? 6'sd0 : 6'sd2) + diff;
      end
    end

endmodule
