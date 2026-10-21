`default_nettype none

// Операции с SPI-флешем (MX25L12833F, 24-битный адрес) поверх spi_flash_phy.
// op: 1 ERASE64K, 2 PROG (len байт из буфера с buf_off, по страницам 256), 3 READ (в буфер),
//     4 CRC32 (IEEE, len байт, одно непрерывное чтение), 5 ID (9F, 3 байта),
//     6 RDSR (faddr[0]=1: RDCR), 7 WRSR (faddr[7:0] SR, faddr[15:8] CR).
// Буфер: синхронное чтение, задержка 1 такт.
module flash_engine #(
    parameter int Half = 2
) (
    input  wire         clk,
    input  wire         start,
    input  wire  [ 2:0] op,
    input  wire  [23:0] faddr,
    input  wire  [23:0] len,
    input  wire  [12:0] buf_off,
    output logic        busy,
    output logic [31:0] result,
    // буфер
    output logic [12:0] b_addr,
    input  wire  [ 7:0] b_rdata,
    output logic        b_we,
    output logic [ 7:0] b_wdata,
    // флеш
    output wire         flash_cs_n,
    output wire         flash_mosi,
    input  wire         flash_miso,
    output wire         flash_wp_n,
    output wire         flash_hold_n
);
  localparam logic [2:0] OpErase = 3'd1, OpProg = 3'd2, OpRead = 3'd3, OpCrc = 3'd4,
      OpId = 3'd5, OpRdsr = 3'd6, OpWrsr = 3'd7;
  localparam logic [31:0] Poly = 32'hEDB8_8320;

  logic       p_cs = 1'b0, p_start = 1'b0, p_busy, p_ready;
  logic [7:0] p_tx = 8'd0, p_rx;
  spi_flash_phy #(
      .Half(Half)
  ) u_phy (
      .clk         (clk),
      .cs_req      (p_cs),
      .start       (p_start),
      .tx          (p_tx),
      .rx          (p_rx),
      .busy        (p_busy),
      .ready       (p_ready),
      .flash_cs_n  (flash_cs_n),
      .flash_mosi  (flash_mosi),
      .flash_miso  (flash_miso),
      .flash_wp_n  (flash_wp_n),
      .flash_hold_n(flash_hold_n)
  );

  function automatic logic [31:0] crc1(input logic [31:0] x);
    crc1 = x[0] ? ((x >> 1) ^ Poly) : (x >> 1);
  endfunction
  function automatic logic [31:0] crc_byte(input logic [31:0] c, input logic [7:0] d);
    crc_byte = crc1(crc1(crc1(crc1(crc1(crc1(crc1(crc1(c ^ {24'd0, d}))))))));
  endfunction

  typedef enum logic [3:0] {
    Idle,
    Wren,
    WrenWait,
    CsGap,
    Cmd,
    CmdWait,
    Data,
    DataWait,
    Poll,
    PollWait,
    Done
  } state_e;

  state_e      state = Idle;
  state_e      ret = Idle;
  logic [ 2:0] op_r = 3'd0;
  logic [23:0] fa = 24'd0;  // адрес следующего байта во флеше
  logic [23:0] left = 24'd0;  // осталось байт операции
  logic [ 8:0] chunk = 9'd0;  // байт до конца текущей транзакции
  logic [ 1:0] hb = 2'd0;  // байт заголовка
  logic        poll_rx = 1'b0;
  logic [ 3:0] gap = 4'd0;
  logic [ 7:0] code;
  logic [ 8:0] page_rem;
  logic        data_end;

  // занят и до готовности phy (пауза перед первыми тактами CCLK): иначе start теряется
  assign busy     = (state != Idle) || !p_ready;
  assign b_wdata  = p_rx;
  assign page_rem = 9'd256 - {1'b0, fa[7:0]};

  always_comb begin
    unique case (op_r)
      OpErase: code = 8'hD8;
      OpProg: code = 8'h02;
      OpRead, OpCrc: code = 8'h03;
      OpId: code = 8'h9F;
      OpWrsr: code = 8'h01;
      default: code = fa[0] ? 8'h15 : 8'h05;
    endcase
    unique case (op_r)
      OpId, OpRdsr, OpWrsr: data_end = (chunk == 0);
      OpProg: data_end = (chunk == 0) || (left == 0);
      default: data_end = (left == 0);
    endcase
  end

  always_ff @(posedge clk) begin
    p_start <= 1'b0;
    b_we    <= 1'b0;
    if (b_we) b_addr <= b_addr + 13'd1;  // READ: следующий байт буфера
    unique case (state)
      Idle: begin
        p_cs <= 1'b0;
        if (start && p_ready) begin
          op_r   <= op;
          fa     <= faddr;
          left   <= len;
          b_addr <= buf_off;
          result <= (op == OpCrc) ? 32'hFFFF_FFFF : 32'd0;
          hb     <= 2'd0;
          if (op == OpErase || op == OpProg || op == OpWrsr) state <= Wren;
          else state <= Cmd;
        end
      end
      Wren: begin
        p_cs    <= 1'b1;
        p_tx    <= 8'h06;
        p_start <= 1'b1;
        state   <= WrenWait;
      end
      WrenWait: begin
        if (!p_start && !p_busy) begin
          ret   <= Cmd;
          state <= CsGap;
        end
      end
      CsGap: begin  // CS# = 1 на 8 тактов, затем ret
        p_cs <= 1'b0;
        gap  <= gap + 4'd1;
        if (gap == 4'd7) begin
          gap   <= 4'd0;
          hb    <= 2'd0;
          state <= ret;
        end
      end
      Cmd: begin  // hb 0: код, 1..3: адрес (для ID и RDSR только код)
        p_cs <= 1'b1;
        unique case (hb)
          2'd0: p_tx <= code;
          2'd1: p_tx <= fa[23:16];
          2'd2: p_tx <= fa[15:8];
          default: p_tx <= fa[7:0];
        endcase
        p_start <= 1'b1;
        state   <= CmdWait;
      end
      CmdWait: begin
        if (!p_start && !p_busy) begin
          hb <= hb + 2'd1;
          if (op_r == OpId || op_r == OpRdsr || op_r == OpWrsr) begin
            chunk <= (op_r == OpId) ? 9'd3 : (op_r == OpWrsr) ? 9'd2 : 9'd1;
            state <= Data;
          end else if (hb == 2'd3) begin
            if (op_r == OpErase) begin
              ret   <= Poll;
              state <= CsGap;
            end else begin
              chunk <= ({15'd0, page_rem} > left) ? left[8:0] : page_rem;
              state <= Data;
            end
          end else state <= Cmd;
        end
      end
      Data: begin
        if (data_end) begin
          if (op_r == OpProg || op_r == OpWrsr) ret <= Poll;
          else ret <= Done;
          state <= CsGap;
        end else begin
          p_tx    <= (op_r == OpProg) ? b_rdata :
                     (op_r == OpWrsr) ? ((chunk == 9'd2) ? fa[7:0] : fa[15:8]) : 8'h00;
          p_start <= 1'b1;
          state   <= DataWait;
          if (op_r == OpProg) b_addr <= b_addr + 13'd1;
        end
      end
      DataWait: begin
        if (!p_start && !p_busy) begin
          chunk <= chunk - 9'd1;
          if (op_r != OpId && op_r != OpRdsr && op_r != OpWrsr) begin
            left <= left - 24'd1;
            fa   <= fa + 24'd1;
          end
          unique case (op_r)
            OpRead: b_we <= 1'b1;
            OpCrc: result <= crc_byte(result, p_rx);
            OpProg, OpWrsr: ;
            default: result <= {result[23:0], p_rx};
          endcase
          state <= Data;
        end
      end
      Poll: begin  // RDSR: 05, затем байт статуса
        p_cs    <= 1'b1;
        p_tx    <= poll_rx ? 8'h00 : 8'h05;
        p_start <= 1'b1;
        state   <= PollWait;
      end
      PollWait: begin
        if (!p_start && !p_busy) begin
          if (!poll_rx) begin
            poll_rx <= 1'b1;
            state   <= Poll;
          end else begin
            poll_rx <= 1'b0;
            if (p_rx[0]) ret <= Poll;  // WIP
            else if (op_r == OpProg && left != 0) ret <= Wren;
            else ret <= Done;
            state <= CsGap;
          end
        end
      end
      Done: begin
        if (op_r == OpCrc) result <= ~result;
        state <= Idle;
      end
      default: state <= Idle;
    endcase
  end
endmodule
