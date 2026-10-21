`default_nettype none

// Выход TMDS на одиночных ножках: P и N каждой линии отдельными LVCMOS33, N = инверсия P.
// Нужен там, где линии HDMI не легли на пары IO_L (модуль i9+ на девборде i5/i9: OBUFDS
// и каскад OSERDES там невозможны). На плате прибора HDMI идёт на настоящие пары,
// там встанет PHY на OBUFDS с тем же входом.
//
// Сериализация: ODDR на 5× такте пикселя, 10 бит за пиксель (5 тактов по 2 бита), младший бит
// первым. Годится до 640×480 с запасом (126 МГц); 720p требует OSERDES 8:1 и редуктора 10:8.
// InvMask[l] = 1 меняет местами P и N линии l (если на плате их перепутали).
module tmds_phy_se #(
    parameter logic [3:0] InvMask = 4'b0000
) (
    input  wire        clk_pix,
    input  wire        clk_5x,      // 5 × clk_pix, синфазный, с того же MMCM
    input  wire  [9:0] lane [3],    // слова TMDS линий 0..2 в домене clk_pix
    output wire  [3:0] pad_p,       // [3] = линия такта
    output wire  [3:0] pad_n
);
  localparam logic [9:0] ClkWord = 10'b0000011111;

  // слово пикселя перехватывается в домен 5× на фазе 0; пути clk_pix → clk_5x синхронны
  logic [9:0] word [4];
  always_ff @(posedge clk_pix) begin
    for (int l = 0; l < 3; l++) word[l] <= lane[l] ^ {10{InvMask[l]}};
    word[3] <= ClkWord ^ {10{InvMask[3]}};
  end

  // фаза 0 должна приходиться на такт 5×, следующий за фронтом clk_pix: детектор фронта
  // clk_pix через переключающийся бит (без опроса такта как данных)
  logic tog = 1'b0, tog_5x = 1'b0, tog_5x_d = 1'b0;
  always_ff @(posedge clk_pix) tog <= ~tog;
  always_ff @(posedge clk_5x) begin
    tog_5x   <= tog;
    tog_5x_d <= tog_5x;
  end
  wire load = tog_5x ^ tog_5x_d;

  logic [9:0] sh [4];
  always_ff @(posedge clk_5x)
    for (int l = 0; l < 4; l++) sh[l] <= load ? word[l] : {2'b00, sh[l][9:2]};

  for (genvar l = 0; l < 4; l++) begin : g_lane
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .SRTYPE("SYNC")) u_p (
        .Q(pad_p[l]), .C(clk_5x), .CE(1'b1), .D1(sh[l][0]), .D2(sh[l][1]), .R(1'b0), .S(1'b0));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .SRTYPE("SYNC")) u_n (
        .Q(pad_n[l]), .C(clk_5x), .CE(1'b1), .D1(~sh[l][0]), .D2(~sh[l][1]), .R(1'b0), .S(1'b0));
  end

endmodule
