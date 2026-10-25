`default_nettype none

// Ядро golden-образа: команды шины ESP (docs/bus-protocol.md), буфер 8 КБ, движок флеша, ICAP.
module golden_core #(
    parameter logic [23:0] ProtTop = 24'h40_0000,  // ниже: golden, стирание и запись запрещены
    parameter logic [ 7:0] Version = 8'd2,  // 2: плоскость меню (команды 40–43)
    parameter int          PorBits = 23  // пауза до чтения BOOTSTS: 2^PorBits тактов (~84 мс)
) (
    input  wire         clk,
    // от qspi_slave
    input  wire         hdr_valid,
    input  wire  [ 7:0] cmd,
    input  wire  [23:0] addr,
    input  wire         wr_valid,
    input  wire  [ 7:0] wr_data,
    input  wire         rd_req,
    output logic [ 7:0] rd_data,
    input  wire         frame_end,
    // плоскость меню (osd_plane): команды 40–43 исполняет она, golden только отвечает без ошибки
    input  wire         osd_busy,
    input  wire         osd_shown,
    input  wire  [15:0] frames,
    // состояние
    output wire         busy,
    output logic [ 7:0] err,
    output wire  [31:0] boot_status,
    output logic [ 7:0] dbg_cmd,
    output logic [ 7:0] rd_start,  // настройка выдачи qspi_slave (TUNE)
    output logic        rd_fall,
    output logic        la_arm,    // отладка: захватить следующий кадр
    output logic        dbg_cmd_valid,
    // флеш
    output wire         flash_cs_n,
    output wire         flash_mosi,
    input  wire         flash_miso,
    output wire         flash_wp_n,
    output wire         flash_hold_n
);
  localparam logic [7:0] CmdId = 8'h01, CmdStatus = 8'h02, CmdBufW = 8'h03, CmdBufR = 8'h04,
      CmdParam = 8'h05, CmdResult = 8'h06, CmdErase = 8'h10, CmdProg = 8'h11, CmdRead = 8'h12,
      CmdCrc = 8'h13, CmdFlId = 8'h14, CmdFlSr = 8'h15, CmdBoot = 8'h20, CmdTune = 8'h07,
      CmdLaArm = 8'h08, CmdFlWrsr = 8'h16, CmdSetWdt = 8'h21, CmdRdReg = 8'h0A,
      CmdIcapDbg = 8'h0B;
  localparam logic [7:0] ErrOk = 8'd0, ErrProt = 8'd1, ErrParam = 8'd2, ErrBusy = 8'd3,
      ErrCmd = 8'd4, ErrKey = 8'd5;
  // ERASE/PROG/BOOT/TUNE исполняются, только если в кадре ровно 4 байта ключа: мусор на шине
  // (перезагрузка ESP, дребезг пинов) не должен стирать флеш или уводить в слот
  localparam logic [31:0] Key = "FBKY";

  // ---------------- буфер 8 КБ: одна запись (QSPI или READ флеша), два чтения ----------------
  logic [7:0] mem[8192];
  logic [12:0] qa = 13'd0;  // адрес QSPI
  logic [ 7:0] q_rdata;
  logic [12:0] e_addr;
  logic [ 7:0] e_rdata, e_wdata;
  logic        e_we;
  logic        q_we;
  always_ff @(posedge clk) begin
    if (e_we) mem[e_addr] <= e_wdata;
    else if (q_we) mem[qa] <= wr_data;
  end
  always_ff @(posedge clk) q_rdata <= mem[qa];
  always_ff @(posedge clk) e_rdata <= mem[e_addr];

  // ---------------- движок флеша ----------------
  logic        e_start = 1'b0;
  logic [ 2:0] e_op = 3'd0;
  logic [23:0] e_faddr = 24'd0;
  logic [23:0] p_len = 24'd0;
  logic [12:0] p_off = 13'd0;
  logic [31:0] e_result;
  logic        e_busy;
  flash_engine u_fe (
      .clk         (clk),
      .start       (e_start),
      .op          (e_op),
      .faddr       (e_faddr),
      .len         (p_len),
      .buf_off     (p_off),
      .busy        (e_busy),
      .result      (e_result),
      .b_addr      (e_addr),
      .b_rdata     (e_rdata),
      .b_we        (e_we),
      .b_wdata     (e_wdata),
      .flash_cs_n  (flash_cs_n),
      .flash_mosi  (flash_mosi),
      .flash_miso  (flash_miso),
      .flash_wp_n  (flash_wp_n),
      .flash_hold_n(flash_hold_n)
  );

  // ---------------- ICAP: BOOTSTS при старте, IPROG по BOOT ----------------
  logic        ic_rd = 1'b0, ic_iprog = 1'b0, ic_busy, ic_rvalid;
  logic [31:0] ic_rdata, wbstar = 32'd0, bootsts = 32'd0;
  logic [31:0] wdt = 32'd0;  // TIMER для следующего BOOT (SET_WDT)
  logic        boot_read = 1'b0;
  logic [  4:0] ic_reg = 5'h16;
  logic [511:0] ic_dbg;
  logic         rr_go = 1'b0;  // импульс RDREG от разбора кадра
  logic [  4:0] rr_reg = 5'h16;
  icap_ctrl u_icap (
      .clk     (clk),
      .rd_start(ic_rd),
      .rd_reg  (ic_reg),
      .iprog   (ic_iprog),
      .wbstar  (wbstar),
      .timer   (wdt),
      .busy    (ic_busy),
      .rdata   (ic_rdata),
      .rvalid  (ic_rvalid),
      .dbg     (ic_dbg)
  );
  logic [PorBits-1:0] por = '0;
  logic [31:0] ic_last = 32'd0;
  logic [ 2:0] boot_try = 3'd0;  // повторы чтения BOOTSTS при старте
  always_ff @(posedge clk) begin
    ic_rd <= 1'b0;
    // BOOTSTS при старте: сразу после загрузки через JTAG ICAP отдаёт мусор (5FFFFDEF, FFFFFFFF),
    // видимо, пока JTAG занят. Старшие 16 бит BOOTSTS всегда 0: иначе повтор через ~84 мс, до 8 раз.
    if (!boot_read) begin
      por <= por + 1'b1;
      if (&por) ic_rd <= 1'b1;
    end
    if (!boot_read && ic_rvalid && ic_reg == 5'h16) begin
      if (ic_rdata[31:16] == 16'd0 || boot_try == 3'd7) boot_read <= 1'b1;
      else begin
        boot_try <= boot_try + 3'd1;
        por      <= '0;
      end
    end
    if (rr_go && !ic_busy) begin  // RDREG: прочитать регистр по запросу ESP
      ic_reg <= rr_reg;
      ic_rd  <= 1'b1;
    end
    if (ic_rvalid) begin
      if (ic_reg == 5'h16) bootsts <= ic_rdata;
      ic_last <= ic_rdata;
    end
  end

  assign boot_status = bootsts;
  assign busy = e_busy || e_start || ic_busy || !boot_read;

  // ---------------- разбор кадра ----------------
  logic [ 7:0] f_cmd = 8'd0;
  logic [23:0] f_addr = 24'd0;
  logic [ 3:0] f_n = 4'd0;  // байт данных в кадре (насыщается)
  logic        key_ok;
  initial begin
    rd_start = 8'd16;  // как fl_tune(16, true) в ESP: после отката golden сразу читается
    rd_fall  = 1'b1;
  end
  logic [63:0] f_param = 64'd0;
  logic [ 5:0] rd_i = 6'd0;  // индекс байта для коротких ответов
  logic [63:0] rd_word;

  always_comb begin
    unique case (f_cmd)
      CmdId: rd_word = {"FBGL", Version, 8'd0, 16'd0};
      CmdStatus: rd_word = {4'd0, osd_shown, osd_busy, err != 0, busy, err, bootsts, frames};
      default: rd_word = {e_result, 32'd0};
    endcase
  end

  assign q_we = (f_cmd == CmdBufW) && wr_valid;
  assign key_ok = (f_n == 4'd4) && (f_param[31:0] == Key);

  function automatic logic is_flash_cmd(input logic [7:0] c);
    is_flash_cmd = (c == CmdErase) || (c == CmdProg) || (c == CmdRead) || (c == CmdCrc) ||
        (c == CmdFlId) || (c == CmdFlSr) || (c == CmdBoot) || (c == CmdFlWrsr);
  endfunction

  always_ff @(posedge clk) begin
    e_start       <= 1'b0;
    ic_iprog      <= 1'b0;
    dbg_cmd_valid <= 1'b0;
    la_arm        <= 1'b0;
    rr_go         <= 1'b0;
    if (q_we) qa <= qa + 13'd1;
    if (hdr_valid) begin
      f_cmd    <= cmd;
      f_addr   <= addr;
      f_n      <= 4'd0;
      qa       <= addr[12:0];
      rd_i     <= 6'd0;
    end
    if (wr_valid && f_cmd != CmdBufW) begin
      f_param <= {f_param[55:0], wr_data};
      if (f_n != 4'hF) f_n <= f_n + 4'd1;
    end
    // ответ: BUF_R из памяти (адрес растёт по rd_req), остальные из rd_word
    // первый rd_req приходит вместе с hdr_valid (адрес = addr), следующие сдвигают адрес
    if (rd_req && !hdr_valid) begin
      if (f_cmd == CmdBufR) qa <= qa + 13'd1;
      else rd_i <= rd_i + 6'd1;
    end
    if (f_cmd == CmdBufR) rd_data <= q_rdata;
    else if (f_cmd == CmdIcapDbg) rd_data <= ic_dbg[511-8*rd_i-:8];
    else rd_data <= rd_word[63-8*rd_i[2:0]-:8];

    if (frame_end) begin
      dbg_cmd       <= f_cmd;
      dbg_cmd_valid <= 1'b1;
      if (is_flash_cmd(f_cmd) && busy) err <= ErrBusy;
      else if ((f_cmd == CmdErase || f_cmd == CmdProg || f_cmd == CmdBoot || f_cmd == CmdTune ||
                f_cmd == CmdFlWrsr || f_cmd == CmdSetWdt) &&
               !key_ok)
        err <= ErrKey;
      else
        unique case (f_cmd)
          CmdParam: begin
            if (f_n == 4'd8) begin
              p_len <= f_param[55:32];
              p_off <= f_param[12:0];
              err   <= (f_param[63:56] != 0 || f_param[31:13] != 0) ? ErrParam : ErrOk;
            end else err <= ErrParam;
          end
          CmdErase: begin
            if (f_addr < ProtTop) err <= ErrProt;
            else if (f_addr[15:0] != 0) err <= ErrParam;
            else begin
              e_op <= 3'd1; e_faddr <= f_addr; e_start <= 1'b1; err <= ErrOk;
            end
          end
          CmdProg: begin
            if (f_addr < ProtTop) err <= ErrProt;
            else if (p_len == 0 || p_len > 24'd8192 || {11'd0, p_off} + p_len > 24'd8192)
              err <= ErrParam;
            else begin
              e_op <= 3'd2; e_faddr <= f_addr; e_start <= 1'b1; err <= ErrOk;
            end
          end
          CmdRead: begin
            if (p_len == 0 || {11'd0, p_off} + p_len > 24'd8192) err <= ErrParam;
            else begin
              e_op <= 3'd3; e_faddr <= f_addr; e_start <= 1'b1; err <= ErrOk;
            end
          end
          CmdCrc: begin
            e_op <= 3'd4; e_faddr <= f_addr; e_start <= 1'b1; err <= ErrOk;
          end
          CmdFlId: begin
            e_op <= 3'd5; e_start <= 1'b1; err <= ErrOk;
          end
          CmdFlSr: begin  // addr[0]=1: регистр конфигурации
            e_op <= 3'd6; e_faddr <= f_addr; e_start <= 1'b1; err <= ErrOk;
          end
          CmdFlWrsr: begin  // addr[7:0] SR (разрешены только BP3..0), addr[15:8] CR
            if ((f_addr[7:0] & ~8'h3C) != 0) err <= ErrParam;
            else begin
              e_op <= 3'd7; e_faddr <= f_addr; e_start <= 1'b1; err <= ErrOk;
            end
          end
          CmdBoot: begin
            wbstar   <= {8'd0, f_addr};
            ic_iprog <= 1'b1;
          end
          CmdSetWdt: begin  // addr: значение в единицах 64 отсчётов, 0 = без watchdog
            wdt <= (f_addr == 0) ? 32'd0 : {2'b01, f_addr, 6'd0};
            err <= ErrOk;
          end
          CmdRdReg: begin  // addr[4:0] регистр; ответ ICAP_DBG: 16 слов, последнее = значение
            rr_reg <= f_addr[4:0];
            rr_go  <= 1'b1;
            err    <= ErrOk;
          end
          CmdLaArm: begin
            if (key_ok) la_arm <= 1'b1;
          end
          CmdTune: begin  // addr[7:0] rd_start, addr[8] rd_fall
            rd_start <= f_addr[7:0];
            rd_fall  <= f_addr[8];
            err      <= ErrOk;
          end
          CmdId, CmdStatus, CmdBufW, CmdBufR, CmdResult, CmdIcapDbg: ;
          8'h40, 8'h41, 8'h42, 8'h43: ;  // osd_plane
          default: err <= ErrCmd;
        endcase
    end
  end
endmodule
