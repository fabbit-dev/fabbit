`default_nettype none

// Тестер памяти NES через порты nes_sdram так, как обращается ядро: запрос по фронту oe/we в
// такте с clkref = 1, данные через 3 такта clk. Проход: запись всего диапазона через порт B,
// затем чтение, чётные адреса через порт A (как PPU), нечётные через B (как CPU), сверка.
// Данные — LFSR от адреса и номера прохода. Один доступ на 4 такта clk.
module sdram_tester #(
    parameter int AddrBits = 22
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        run,         // уровень: гонять проходы подряд
    input  wire        clkref,
    input  wire        mem_busy,
    output logic [21:0] addr = '0,
    output logic       oe_a = 1'b0,
    output logic       oe_b = 1'b0,
    output logic       we_b = 1'b0,
    output logic  [7:0] din = '0,
    input  wire  [7:0] dout_a,
    input  wire  [7:0] dout_b,
    output logic [15:0] passes = '0,
    output logic [31:0] errors = '0,
    output logic [21:0] err_addr = '0,  // первая ошибка
    output logic  [7:0] err_got = '0,
    output logic  [7:0] err_want = '0,
    output wire        idle          // стоит: run снят, проход дописан, счётчики не меняются
);
  function automatic logic [7:0] pattern(input logic [21:0] a, input logic [15:0] p);
    logic [31:0] h;
    h = {10'd0, a} * 32'h9E37_79B1 ^ {p, p};
    return h[23:16] ^ h[7:0];
  endfunction

  typedef enum logic [1:0] {Idle, Write, Read} phase_t;
  phase_t phase = Idle;
  logic [1:0] t = '0;  // такт доступа: 0 — запрос (clkref = 1), 3 — данные чтения готовы
  logic last = 1'b0;
  logic [21:0] chk_addr = '0;
  logic [15:0] chk_pass = '0;
  logic chk = 1'b0, chk_a = 1'b0;
  localparam logic [21:0] Top = 22'((64'd1 << AddrBits) - 1);
  assign idle = phase == Idle;
  wire [7:0] got = chk_a ? dout_a : dout_b;
  wire [7:0] want = pattern(chk_addr, chk_pass);

  always_ff @(posedge clk)
    if (rst) begin
      phase  <= Idle;
      oe_a   <= 1'b0;
      oe_b   <= 1'b0;
      we_b   <= 1'b0;
      passes <= '0;
      errors <= '0;
      chk    <= 1'b0;
    end else begin
      // проверка прочитанного: данные порта готовы к такту t = 3 после запроса
      if (chk && t == 2'd3) begin
        if (got != want) begin
          if (errors == 0) begin
            err_addr <= chk_addr;
            err_got  <= got;
            err_want <= want;
          end
          if (errors != '1) errors <= errors + 1'b1;
        end
        chk <= 1'b0;
      end
      t <= t + 2'd1;
      if (t == 2'd1) begin  // снять запрос: следующий будет снова фронтом
        oe_a <= 1'b0;
        oe_b <= 1'b0;
        we_b <= 1'b0;
      end
      case (phase)
        Idle:
        if (run && !mem_busy && clkref == 1'b0) begin
          phase <= Write;
          addr  <= '0;
          t     <= 2'd2;  // сейчас clkref = 0: дальше t = 2 (1), t = 3 (0), t = 0 (1)
        end
        Write:
        if (t == 2'd3) begin  // в следующем такте clkref = 1: выставить запрос
          we_b <= 1'b1;
          din  <= pattern(addr, passes);
          last <= addr == Top;
        end else if (t == 2'd1) begin
          if (last) begin
            phase <= Read;
            addr  <= '0;
          end else addr <= addr + 1'b1;
        end
        Read:
        if (t == 2'd3) begin
          oe_a     <= !addr[0];
          oe_b     <= addr[0];
          chk_addr <= addr;
          chk_pass <= passes;
          chk_a    <= !addr[0];
          last     <= addr == Top;
        end else if (t == 2'd1) begin
          chk <= 1'b1;
          if (last) begin
            passes <= passes + 1'b1;
            phase  <= run ? Write : Idle;
            addr   <= '0;
          end else addr <= addr + 1'b1;
        end
        default: phase <= Idle;
      endcase
    end

endmodule
