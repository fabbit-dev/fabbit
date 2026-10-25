`default_nettype none

// Передатчик DVI по разъёму HDMI: последняя ступень тракта. Берёт vpx_t, синхро идёт
// управляющими словами линии 0. Задержка от входа до ножек: 2 такта пикселя + сериализатор.
// Звук (островки данных HDMI) сюда добавится отдельной ступенью перед кодерами.
module hdmi_tx
  import video_pkg::*;
#(
    parameter logic [3:0] InvMask = 4'b0000
) (
    input  wire        clk_pix,
    input  wire        clk_5x,
    input  vpx_t       px,
    output wire  [3:0] pad_p,
    output wire  [3:0] pad_n
);
  logic [9:0] lane [3];

  tmds_encoder u_b (
      .clk(clk_pix), .ce(1'b1), .d(px.b), .c({px.vs, px.hs}), .de(px.de), .q(lane[0]));
  tmds_encoder u_g (.clk(clk_pix), .ce(1'b1), .d(px.g), .c(2'b00), .de(px.de), .q(lane[1]));
  tmds_encoder u_r (.clk(clk_pix), .ce(1'b1), .d(px.r), .c(2'b00), .de(px.de), .q(lane[2]));

  tmds_phy_se #(.InvMask(InvMask)) u_phy (
      .clk_pix(clk_pix), .clk_5x(clk_5x), .lane(lane), .pad_p(pad_p), .pad_n(pad_n));

endmodule
