`default_nettype none

// Асинхронная FIFO по Cummings («Simulation and Synthesis Techniques for Asynchronous FIFO Design»,
// SNUG 2002): двоичные указатели внутри домена, через границу идут коды Грея по 2 триггера с
// ASYNC_REG, полна/пуста считаются каждая в своём домене. Память ram_sdp (BRAM, чтение регистровое).
// Вход и выход — потоки valid/ready. Выход отдаёт слово не чаще раза в 3 такта rclk: этого хватает
// для загрузки ROM и команд, а памяти нужен один порт чтения без обходных регистров.
// В XDC: set_max_delay -datapath_only (период быстрого такта) на пути *gray_q* → *gray_s1*.
module fifo_async #(
    parameter int Width = 8,
    parameter int Depth = 4096,  // степень двойки
    localparam int Aw = $clog2(Depth)
) (
    input  wire              wclk,
    input  wire              wrst,
    input  wire              in_valid,
    output wire              in_ready,
    input  wire  [Width-1:0] in_data,
    output logic [Aw:0]      wlevel,     // занято слов, со стороны записи (оценка сверху)

    input  wire              rclk,
    input  wire              rrst,
    output logic             out_valid,
    input  wire              out_ready,
    output logic [Width-1:0] out_data
);
  function automatic logic [Aw:0] bin2gray(input logic [Aw:0] b);
    return b ^ (b >> 1);
  endfunction

  function automatic logic [Aw:0] gray2bin(input logic [Aw:0] g);
    logic [Aw:0] b;
    for (int i = Aw; i >= 0; i--) b[i] = (i == Aw) ? g[i] : b[i+1] ^ g[i];
    return b;
  endfunction

  // ---- запись ----
  logic [Aw:0] wbin = '0, wgray_q = '0;
  (* ASYNC_REG = "TRUE" *) logic [Aw:0] rgray_s1 = '0, rgray_s2 = '0;
  wire [Aw:0] rbin_w = gray2bin(rgray_s2);
  wire full = (wbin[Aw] != rbin_w[Aw]) && (wbin[Aw-1:0] == rbin_w[Aw-1:0]);
  wire push = in_valid && !full;
  assign in_ready = !full;

  always_ff @(posedge wclk) begin
    rgray_s1 <= rgray_q;
    rgray_s2 <= rgray_s1;
    if (wrst) begin
      wbin    <= '0;
      wgray_q <= '0;
    end else if (push) begin
      wbin    <= wbin + 1'b1;
      wgray_q <= bin2gray(wbin + 1'b1);
    end
    wlevel <= wbin - rbin_w;
  end

  // ---- чтение ----
  logic [Aw:0] rbin = '0, rgray_q = '0;
  (* ASYNC_REG = "TRUE" *) logic [Aw:0] wgray_s1 = '0, wgray_s2 = '0;
  wire empty = (rgray_q == wgray_s2);
  logic pend = 1'b0;
  wire issue = !empty && !out_valid && !pend;
  wire [Width-1:0] rdata;

  always_ff @(posedge rclk) begin
    wgray_s1 <= wgray_q;
    wgray_s2 <= wgray_s1;
    if (rrst) begin
      rbin      <= '0;
      rgray_q   <= '0;
      pend      <= 1'b0;
      out_valid <= 1'b0;
    end else begin
      pend <= issue;
      if (issue) begin
        rbin    <= rbin + 1'b1;
        rgray_q <= bin2gray(rbin + 1'b1);
      end
      if (pend) begin
        out_valid <= 1'b1;
        out_data  <= rdata;
      end else if (out_ready) begin
        out_valid <= 1'b0;
      end
    end
  end

  ram_sdp #(.Width(Width), .Depth(Depth)) u_mem (
      .wclk(wclk), .we(push), .waddr(wbin[Aw-1:0]), .wdata(in_data),
      .rclk(rclk), .re(issue), .raddr(rbin[Aw-1:0]), .rdata(rdata));

endmodule
