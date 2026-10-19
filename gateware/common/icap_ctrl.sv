`default_nettype none

// ICAPE2: чтение регистра конфигурации и IPROG с заданным WBSTAR (UG470, гл. 5 и 7).
// Слова ICAP подаются с перестановкой бит внутри каждого байта.
// clk <= 100 МГц.
// openXC7 (prjxray-db 2026-09) ICAP не включает: регистры читаются 0, IPROG не действует.
// Модуль, где нужен ICAP (golden), собирается в Vivado.
module icap_ctrl (
    input  wire        clk,
    input  wire        rd_start,  // прочитать регистр rd_reg
    input  wire [ 4:0] rd_reg,    // 0x07 STAT, 0x10 WBSTAR, 0x16 BOOTSTS
    input  wire        iprog,     // WBSTAR <= wbstar, затем IPROG
    input  wire [31:0] wbstar,
    input  wire [31:0] timer,     // TIMER перед IPROG: бит 30 TIMER_CFG_MON, 29:0 значение; 0 = нет
    output logic       busy,
    output logic [31:0] rdata,
    output logic       rvalid,
    output logic [511:0] dbg    // выход ICAP на 16 тактах чтения (после перестановки)
);
  localparam logic [31:0] Dummy = 32'hFFFF_FFFF;
  localparam logic [31:0] Sync = 32'hAA99_5566;
  localparam logic [31:0] Noop = 32'h2000_0000;
  localparam logic [31:0] WrCmd = 32'h3000_8001;  // type1 write CMD, 1 слово
  localparam logic [31:0] WrWbstar = 32'h3002_0001;  // type1 write WBSTAR, 1 слово
  localparam logic [31:0] WrTimer = 32'h3002_2001;  // type1 write TIMER (0x11), 1 слово
  localparam logic [31:0] CmdIprog = 32'h0000_000F;
  localparam logic [31:0] CmdDesync = 32'h0000_000D;

  function automatic logic [31:0] bitswap(input logic [31:0] w);
    bitswap = {w[24], w[25], w[26], w[27], w[28], w[29], w[30], w[31],
            w[16], w[17], w[18], w[19], w[20], w[21], w[22], w[23],
            w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15],
            w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7]};
  endfunction

  logic        csib = 1'b1;
  logic        rdwrb = 1'b0;
  logic [31:0] din = Dummy;
  logic [31:0] dout;

  ICAPE2 #(
      .ICAP_WIDTH("X32")
  ) u_icap (
      .CLK  (clk),
      .CSIB (csib),
      .RDWRB(rdwrb),
      .I    (bitswap(din)),
      .O    (dout)
  );

  typedef enum logic [2:0] {
    Idle,
    WrSeq,
    RdGap,
    RdWait,
    RdEnd,
    DsSeq
  } state_e;

  state_e      state = Idle;
  logic [ 3:0] step = 4'd0;
  logic        is_iprog = 1'b0;
  logic [ 4:0] reg_r = 5'd0;
  logic [31:0] wb_r = 32'd0;
  logic [31:0] tm_r = 32'd0;

  assign busy = (state != Idle);

  // последовательность записи: для чтения и для IPROG
  logic [31:0] wr_word;
  logic [ 3:0] wr_len;
  always_comb begin
    wr_word = Noop;
    if (is_iprog) begin
      // watchdog конфигурации (TIMER) до IPROG: битый или пустой слот даст откат на golden
      wr_len = 4'd10;
      unique case (step)
        4'd0: wr_word = Dummy;
        4'd1: wr_word = Sync;
        4'd2: wr_word = Noop;
        4'd3: wr_word = WrTimer;
        4'd4: wr_word = tm_r;
        4'd5: wr_word = WrWbstar;
        4'd6: wr_word = wb_r;
        4'd7: wr_word = WrCmd;
        4'd8: wr_word = CmdIprog;
        default: wr_word = Noop;
      endcase
    end else begin
      wr_len = 4'd6;
      unique case (step)
        4'd0: wr_word = Dummy;
        4'd1: wr_word = Sync;
        4'd2: wr_word = Noop;
        // type1 read: [31:29]=001, [28:27]=01, адрес регистра [17:13], 1 слово
        4'd3: wr_word = {3'b001, 2'b01, 9'd0, reg_r, 2'b00, 11'd1};
        default: wr_word = Noop;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    rvalid <= 1'b0;
    unique case (state)
      Idle: begin
        csib  <= 1'b1;
        rdwrb <= 1'b0;
        step  <= 4'd0;
        if (iprog) begin
          is_iprog <= 1'b1;
          wb_r     <= wbstar;
          tm_r     <= timer;
          state    <= WrSeq;
        end else if (rd_start) begin
          is_iprog <= 1'b0;
          reg_r    <= rd_reg;
          state    <= WrSeq;
        end
      end
      WrSeq: begin
        csib  <= 1'b0;
        rdwrb <= 1'b0;
        din   <= wr_word;
        if (step == wr_len - 4'd1) begin
          step  <= 4'd0;
          if (is_iprog) state <= DsSeq;
          else state <= RdGap;
        end else step <= step + 4'd1;
      end
      RdGap: begin  // CSIB=1 перед сменой направления
        csib  <= 1'b1;
        rdwrb <= 1'b1;
        state <= RdWait;
      end
      RdWait: begin
        csib <= 1'b0;
        step <= step + 4'd1;
        dbg  <= {dbg[479:0], bitswap(dout)};
        // данные регистра на выходе ICAP только на 4-5 такте после CSIB=0, до и после — слово
        // состояния (FFFFFFDB). Проверено на железе icapdbg 2026-10-15
        if (step == 4'd5) rdata <= bitswap(dout);
        if (step == 4'd15) begin
          rvalid <= 1'b1;
          state  <= RdEnd;
        end
      end
      RdEnd: begin
        csib  <= 1'b1;
        rdwrb <= 1'b0;
        step  <= 4'd0;
        state <= DsSeq;
      end
      DsSeq: begin  // DESYNC; для IPROG сюда не доходим: ПЛИС уже перезагружается
        csib  <= 1'b0;
        rdwrb <= 1'b0;
        unique case (step)
          4'd0: din <= WrCmd;
          4'd1: din <= CmdDesync;
          default: din <= Noop;
        endcase
        if (step == 4'd3) state <= Idle;
        step <= step + 4'd1;
      end
      default: state <= Idle;
    endcase
  end
endmodule
