`default_nettype none

// Тестовый источник: красит поток от video_timing. Задержка 1 такт.
//   sel 0: 8 цветных полос и бегущая диагональ (кадры идут);
//   sel 1: серая сетка 32 пикселя и красная рамка по краю 640×480 (масштаб, обрезка, сдвиг);
//   sel 2: градиенты R, G, B и серый полосами по 128 строк;
//   sel 3: белое поле (размах, «снег» на длинном кабеле).
module video_pattern
  import video_pkg::*;
(
    input  wire        clk,
    input  wire        ce,
    input  wire  [1:0] sel,
    input  vpx_t       px_in,
    output vpx_t       px_out
);
  logic [7:0] frame = '0;

  always_ff @(posedge clk)
    if (ce && px_in.sof) frame <= frame + 1'b1;

  // x * 51 / 128 = 0..254 на 640 пикселях: уровень градиента, его старшие 3 бита: номер полосы
  function automatic logic [23:0] color(input vpx_t p, input logic [1:0] s, input logic [7:0] f);
    logic [17:0] xs;
    logic [7:0]  v;
    logic [2:0]  bar;
    logic        edge_px;
    xs = 18'(p.x) * 18'd51;
    v = xs[14:7];
    bar = xs[14:12];
    edge_px = p.x == 0 || p.y == 0 || p.x == 12'(Vmode640x480.h_active - 1) ||
              p.y == 12'(Vmode640x480.v_active - 1);
    case (s)
      2'd0: begin
        if (p.x[7:0] + f == p.y[7:0]) return 24'hFFFFFF;
        return {{8{bar[2]}}, {8{bar[1]}}, {8{bar[0]}}};
      end
      2'd1: begin
        if (edge_px) return 24'hFF0000;
        if (p.x[4:0] == 0 || p.y[4:0] == 0) return 24'h808080;
        return 24'h000000;
      end
      2'd2:
      case (p.y[8:7])
        2'd0: return {v, 16'h0000};
        2'd1: return {8'h00, v, 8'h00};
        2'd2: return {16'h0000, v};
        default: return {v, v, v};
      endcase
      default: return 24'hFFFFFF;
    endcase
  endfunction

  logic [23:0] c;
  always_comb c = color(px_in, sel, frame);

  always_ff @(posedge clk)
    if (ce) px_out <= vpx_rgb(px_in, c[23:16], c[15:8], c[7:0]);

endmodule
