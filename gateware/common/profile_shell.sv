`default_nettype none

// Оболочка профиля: ответ ESP по шине quad SPI (docs/bus-protocol.md) в домене clk (100 МГц).
//   01 ID          чтение 8: "FBPR", версия, режим 1, id профиля
//   07 TUNE        ключ: момент выдачи данных
//   22 REBOOT      ключ: IPROG на адрес 0 (golden), если UseIcap (сборка Vivado)
//   30 CSR_W       запись 4·n: регистры профиля с индекса addr[7:0], слова старшим байтом вперёд
//   31 CSR_R       чтение 4·n: то же на чтение
//   32 STREAM      запись n: байты в поток канала addr[7:0] (без обратного давления: свободное место
//                  ESP узнаёт из регистра профиля)
//   33 PAD         запись 4: кнопки {пад 1, пад 0} по 16 бит (раскладка RetroPad, docs/bus-protocol.md);
//                  слово принимается целиком по CS#↑ и только при ровно 4 байтах
//   34 CAPTURE_R   чтение замороженного захвата с байтового адреса addr[23:0], если Readback
// Регистры и поток видит профиль в домене clk; переход в свои такты — его забота (common/cdc).
module profile_shell #(
    parameter logic [15:0] ProfileId = 16'd0,
    parameter logic [ 7:0] Version = 8'd3,
    parameter bit          UseIcap = 1'b0,
    parameter bit          Readback = 1'b0
) (
    input  wire        clk,         // 100 МГц
    input  wire        rst,         // синхронный сброс, пока PLL не захватил частоту
    input  wire        esp_sck,
    input  wire        esp_cs_n,
    input  wire  [3:0] d_in,
    output wire  [3:0] d_out,
    output wire        d_oe,
    output wire        irq,         // 1: профиль готов
    // регистры профиля
    output logic        csr_we,
    output logic [ 7:0] csr_waddr,
    output logic [31:0] csr_wdata,
    output wire  [ 7:0] csr_raddr,
    input  wire  [31:0] csr_rdata,  // комбинационно от csr_raddr, читается через такт
    // поток байтов
    output logic        st_valid,
    output logic [ 7:0] st_chan,
    output logic [ 7:0] st_data,
    // кнопки: {пад 1, пад 0}, pad_stb на такт после смены
    output logic [31:0] pad = 32'd0,
    output logic        pad_stb = 1'b0,
    // Random-access readback: no destructive pop, profile returns zero if unavailable.
    // Data must settle within two clk cycles of rb_addr changing.
    output wire [23:0] rb_addr,
    input  wire [ 7:0] rb_data
);
  localparam logic [31:0] Key = "FBKY";
  localparam int ReadIndexBits = Readback ? 24 : 10;
  localparam logic [7:0] CmdId = 8'h01, CmdTune = 8'h07, CmdReboot = 8'h22;
  localparam logic [7:0] CmdCsrW = 8'h30, CmdCsrR = 8'h31, CmdStream = 8'h32,
                         CmdPad = 8'h33, CmdCaptureR = 8'h34;

  logic [7:0] rd_start = 8'd16;
  logic       rd_fall = 1'b1;
  logic hdr_valid, wr_valid, rd_req, frame_end;
  logic [7:0] cmd, wr_data;
  logic [7:0] rd_data = 8'd0;
  logic [23:0] addr;
  qspi_slave u_q (
      .clk(clk), .rd_start(rd_start), .rd_fall(rd_fall), .sck(esp_sck), .cs_n(esp_cs_n),
      .d_in(d_in), .d_out(d_out), .d_oe(d_oe), .hdr_valid(hdr_valid), .cmd(cmd), .addr(addr),
      .wr_valid(wr_valid), .wr_data(wr_data), .rd_req(rd_req), .rd_data(rd_data),
      .frame_end(frame_end)
  );
  assign irq = 1'b1;

  logic [7:0] f_cmd = 8'd0;
  logic [23:0] f_addr = 24'd0;
  logic [31:0] f_key = 32'd0;
  logic [3:0] f_n = 4'd0;      // байтов данных в кадре, до 15
  logic [ReadIndexBits-1:0] rd_i = '0;  // номер байта чтения в кадре
  logic [1:0] wb = 2'd0;       // байт внутри слова CSR_W
  logic [7:0] widx = 8'd0;
  wire [63:0] id_word = {"FBPR", Version, 8'd1, ProfileId};

  assign csr_raddr = f_addr[7:0] + 8'(rd_i >> 2);
  wire [24:0] rb_sum = {1'b0, f_addr} + 25'(rd_i);
  assign rb_addr = rb_sum[24] ? 24'hFFFFFF : rb_sum[23:0];

  always_ff @(posedge clk) begin
    csr_we   <= 1'b0;
    st_valid <= 1'b0;
    if (hdr_valid) begin
      f_cmd  <= cmd;
      f_addr <= addr;
      f_n    <= 4'd0;
      rd_i   <= '0;
      wb     <= 2'd0;
      widx   <= addr[7:0];
    end
    if (rd_req && !hdr_valid && (!Readback || !(&rd_i))) rd_i <= rd_i + 1'b1;
    case (f_cmd)
      CmdId:   rd_data <= id_word[63-8*rd_i[2:0]-:8];
      CmdCsrR: rd_data <= csr_rdata[31-8*rd_i[1:0]-:8];
      CmdCaptureR: rd_data <= Readback ? rb_data : 8'd0;
      default: rd_data <= 8'h00;
    endcase
    if (wr_valid) begin
      f_key <= {f_key[23:0], wr_data};
      if (f_n != 4'hF) f_n <= f_n + 4'd1;
      if (f_cmd == CmdCsrW) begin
        csr_wdata <= {csr_wdata[23:0], wr_data};
        wb <= wb + 2'd1;
        if (wb == 2'd3) begin
          csr_we    <= 1'b1;
          csr_waddr <= widx;
          widx      <= widx + 8'd1;
        end
      end
      if (f_cmd == CmdStream) begin
        st_valid <= 1'b1;
        st_chan  <= f_addr[7:0];
        st_data  <= wr_data;
      end
    end
    pad_stb <= 1'b0;
    if (frame_end && f_cmd == CmdPad && f_n == 4'd4) begin
      pad     <= f_key;
      pad_stb <= 1'b1;
    end
    if (frame_end && f_cmd == CmdTune && f_n == 4'd4 && f_key == Key) begin
      rd_start <= f_addr[7:0];
      rd_fall  <= f_addr[8];
    end
    // до захвата PLL такт нестабилен и регистры без сброса набирают мусор: на стенде выдача
    // данных молчала до первого TUNE, CSR профиля читались случайными
    if (rst) begin
      rd_start <= 8'd16;
      rd_fall  <= 1'b1;
      f_cmd    <= 8'd0;
      pad      <= 32'd0;
      pad_stb  <= 1'b0;
      csr_we   <= 1'b0;
      st_valid <= 1'b0;
    end
  end

  // возврат в golden: IPROG на адрес 0 (ICAP работает только в сборке Vivado)
  wire reboot = frame_end && f_cmd == CmdReboot && f_n == 4'd4 && f_key == Key;
  if (UseIcap) begin : g_icap
    icap_ctrl u_icap (
        .clk(clk), .rd_start(1'b0), .rd_reg(5'd0), .iprog(reboot), .wbstar(32'd0), .timer(32'd0),
        .busy(), .rdata(), .rvalid(), .dbg());
  end

endmodule
