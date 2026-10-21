`default_nettype none

// Прозвонка всей гребёнки P3: "P xxxxxxxx", бит N = пин P3-N (N = 3..28, сигнальные).
module wiretest_p3 (
    input  wire        clk,
    output wire        led,
    output wire        uart_tx,
    input  wire        p3_3,
    input  wire        p3_4,
    input  wire        p3_5,
    input  wire        p3_6,
    input  wire        p3_7,
    input  wire        p3_9,
    input  wire        p3_12,
    input  wire        p3_13,
    input  wire        p3_14,
    input  wire        p3_15,
    input  wire        p3_16,
    input  wire        p3_17,
    input  wire        p3_18,
    input  wire        p3_19,
    input  wire        p3_22,
    input  wire        p3_24,
    input  wire        p3_25,
    input  wire        p3_26,
    input  wire        p3_27,
    input  wire        p3_28
);
  wire [31:0] p3;
  assign p3[3] = p3_3;
  assign p3[4] = p3_4;
  assign p3[5] = p3_5;
  assign p3[6] = p3_6;
  assign p3[7] = p3_7;
  assign p3[9] = p3_9;
  assign p3[12] = p3_12;
  assign p3[13] = p3_13;
  assign p3[14] = p3_14;
  assign p3[15] = p3_15;
  assign p3[16] = p3_16;
  assign p3[17] = p3_17;
  assign p3[18] = p3_18;
  assign p3[19] = p3_19;
  assign p3[22] = p3_22;
  assign p3[24] = p3_24;
  assign p3[25] = p3_25;
  assign p3[26] = p3_26;
  assign p3[27] = p3_27;
  assign p3[28] = p3_28;
  assign p3[0] = 1'b0;
  assign p3[1] = 1'b0;
  assign p3[2] = 1'b0;
  assign p3[8] = 1'b0;
  assign p3[10] = 1'b0;
  assign p3[11] = 1'b0;
  assign p3[20] = 1'b0;
  assign p3[21] = 1'b0;
  assign p3[23] = 1'b0;
  assign p3[29] = 1'b0;
  assign p3[30] = 1'b0;
  assign p3[31] = 1'b0;
  logic [31:0] s1 = 32'd0, s2 = 32'd0, last = 32'hFFFF_FFFF;
  logic [19:0] t = 20'd0;
  logic        pr_start = 1'b0, pr_busy;
  assign led = s2[7];
  uart_hexline u_pr (
      .clk  (clk),
      .start(pr_start),
      .tag  ("P"),
      .value(last),
      .busy (pr_busy),
      .tx   (uart_tx)
  );
  always_ff @(posedge clk) begin
    s1       <= p3;
    s2       <= s1;
    pr_start <= 1'b0;
    t        <= t + 20'd1;
    if (t == 0 && s2 != last && !pr_busy) begin
      last     <= s2;
      pr_start <= 1'b1;
    end
  end
endmodule
