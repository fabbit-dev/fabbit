`default_nettype none

// Ведомый quad SPI (режим 0), оверсемплинг на clk (SCK <= clk/8).
// Кадр: CS#=0, команда 8 бит + адрес 24 бита по 4 линиям (8 тактов SCK), затем
//  - запись: данные от ESP, байт за байтом;
//  - чтение: dummy-такты, затем данные к ESP. Момент выдачи настраивается (команда TUNE):
//    первый нибл выставляется на фронте, когда принято rd_start передних фронтов SCK с начала
//    кадра; rd_fall=1 меняет данные по заднему фронту вместо переднего.
// IO0 = D[0] .. IO3 = D[3]; старший нибл первым, бит 7 на IO3.
module qspi_slave (
    input  wire        clk,
    input  wire  [7:0] rd_start,   // передних фронтов до первого нибла (8 заголовок + dummy + ...)
    input  wire        rd_fall,
    input  wire        sck,
    input  wire        cs_n,
    input  wire  [3:0] d_in,
    output logic [3:0] d_out,
    output logic       d_oe,
    // к ядру
    output logic       hdr_valid,  // импульс: cmd и addr приняты
    output logic [7:0] cmd,
    output logic [23:0] addr,
    output logic       wr_valid,   // импульс: байт данных от ESP
    output logic [7:0] wr_data,
    output logic       rd_req,     // импульс: следующий байт в rd_data через RdLat тактов
    input  wire  [7:0] rd_data,
    output logic       frame_end   // импульс: CS# поднялся
);
  logic [2:0] sck_s = 3'b000;
  logic [2:0] cs_s = 3'b111;
  logic [3:0] d_s1 = 4'h0, d_s2 = 4'h0;
  always_ff @(posedge clk) begin
    sck_s <= {sck_s[1:0], sck};
    cs_s  <= {cs_s[1:0], cs_n};
    d_s1  <= d_in;
    d_s2  <= d_s1;
  end
  // SCK: уровень принимается, когда две выборки подряд совпадают (фильтр выбросов <= 10 нс)
  logic sck_q = 1'b0, sck_qd = 1'b0;
  always_ff @(posedge clk) begin
    if (sck_s[1] == sck_s[2]) sck_q <= sck_s[1];
    sck_qd <= sck_q;
  end
  wire rise = sck_q & ~sck_qd;
  wire fall = ~sck_q & sck_qd;
  wire out_edge = rd_fall ? fall : rise;
  // CS#: фильтр выбросов. На макетке при выдаче данных ловили импульс CS#=1 длиной 10 нс
  // посреди чтения (наводка), он обрывал кадр. Кадр кончается, если CS#=1 держится 4 такта.
  logic [2:0] cs_hi = 3'd0;
  logic       active = 1'b0;
  always_ff @(posedge clk) begin
    if (!cs_s[1]) begin
      cs_hi  <= 3'd0;
      active <= 1'b1;
    end else if (cs_hi != 3'd4) cs_hi <= cs_hi + 3'd1;
    else active <= 1'b0;
  end

  logic [ 7:0] ncnt = 8'd0;  // номер фронта SCK в кадре
  logic [31:0] hdr = 32'd0;
  logic        is_read = 1'b0;
  logic        hi = 1'b1;  // принимаем/отдаём старший нибл
  logic [ 3:0] wr_hi = 4'h0;
  logic [ 7:0] rd_byte = 8'd0;
  localparam logic [2:0] RdLat = 3'd4;  // ядро: rd_data валиден через 4 такта после rd_req
  logic [2:0]  rd_pend = 3'd0;

  // команды чтения (см. docs/protocol.md)
  function automatic logic read_cmd(input logic [7:0] c);
    read_cmd = (c == 8'h01) || (c == 8'h02) || (c == 8'h04) || (c == 8'h06) || (c == 8'h0B);
  endfunction

  always_ff @(posedge clk) begin
    hdr_valid <= 1'b0;
    wr_valid  <= 1'b0;
    rd_req    <= 1'b0;
    frame_end <= 1'b0;
    if (rd_pend != 0) begin
      rd_pend <= rd_pend - 3'd1;
      if (rd_pend == 3'd1) rd_byte <= rd_data;
    end
    if (!active) begin
      if (ncnt != 0) frame_end <= 1'b1;
      ncnt <= 8'd0;
      d_oe <= 1'b0;
      hi   <= 1'b1;
    end else begin
      if (rise) begin
        if (ncnt != 8'hFF) ncnt <= ncnt + 8'd1;
        if (ncnt < 8'd8) begin
          hdr <= {hdr[27:0], d_s2};
          if (ncnt == 8'd7) begin
            cmd       <= hdr[27:20];
            addr      <= {hdr[19:0], d_s2};
            hdr_valid <= 1'b1;
            is_read   <= read_cmd(hdr[27:20]);
            if (read_cmd(hdr[27:20])) begin
              rd_req  <= 1'b1;
              rd_pend <= RdLat;
            end
          end
        end else if (!is_read) begin
          if (hi) wr_hi <= d_s2;
          else begin
            wr_data  <= {wr_hi, d_s2};
            wr_valid <= 1'b1;
          end
          hi <= ~hi;
        end
      end
      // передних фронтов с начала кадра, включая текущий
      if (out_edge && is_read && ncnt >= 8'd8 &&
          ((rise ? {1'b0, ncnt} + 9'd1 : {1'b0, ncnt}) >= {1'b0, rd_start})) begin
        d_oe <= 1'b1;
        if (hi) d_out <= rd_byte[7:4];
        else begin
          d_out   <= rd_byte[3:0];
          rd_req  <= 1'b1;
          rd_pend <= RdLat;
        end
        hi <= ~hi;
      end
    end
  end
endmodule
