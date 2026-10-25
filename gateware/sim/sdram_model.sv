`default_nettype none
`timescale 1ns / 1ps

// Поведенческая модель SDR SDRAM 2M×32 (как M12L64322A: 4 банка, строка 11 бит, столбец 8 бит),
// только то, что нужно контроллерам стенда: MRS (CL 2/3, BL 1), ACT, READ/WRITE с автопредзарядом
// по A10, PRE, REF. Данные чтения выходят через CL тактов, держатся tOH после следующего фронта.
// Проверяет tRCD (в нс), чтение/запись в закрытую строку и команды без MRS; нарушения считает в errors.
module sdram_model #(
    parameter realtime TAc = 5.4ns,  // выход данных после фронта (CL2, -6)
    parameter realtime TOh = 2.5ns,  // удержание после следующего фронта
    parameter time TRcd = 15ns,  // legacy default; strict fixtures override21ns
    // Optional conditional ESMT(2S)-7 timing per programmed CAS. Legacy model
    // defaults intentionally unchanged for the retained NES baseline test.
    parameter bit DynamicCasTiming = 1'b0,
    parameter realtime TAcCl2 = 8ns,
    parameter realtime TAcCl3 = 6ns
) (
    input  wire        clk,
    input  wire        cke,
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire  [1:0] ba,
    input  wire [10:0] a,
    input  wire  [3:0] dqm,
    inout  wire [31:0] dq
);
  logic [31:0] mem [bit [20:0]];  // {ba, row, col}
  logic [10:0] row [4];
  bit          open_ [4];
  time         act_t [4];
  int          cyc = 0, cl = 0, errors = 0;
  bit          mode_set = 0;

  // конвейер чтения: адрес слова или -1
  int          rpipe [4] = '{-1, -1, -1, -1};
  logic [31:0] dq_o = '0;
  logic        dq_e = 0;
  assign dq = dq_e ? dq_o : 'z;

  task automatic err(input string s);
    errors++;
    if (errors <= 10) $display("  SDRAM: %s (такт %0d)", s, cyc);
  endtask

  // один процесс на фронт: сначала выдача данных из конвейера, потом команда
  always @(posedge clk) begin
    int h;
    cyc++;
    h = rpipe[0];
    rpipe = '{rpipe[1], rpipe[2], rpipe[3], -1};
    fork
      begin
        #(TOh) dq_e = 0;
      end
      if (h >= 0) begin
        #(DynamicCasTiming ? (cl == 2 ? TAcCl2 : TAcCl3) : TAc)
            dq_o = mem.exists(h[20:0]) ? mem[h[20:0]] : 32'hxxxx_xxxx;
        dq_e = 1;
      end
    join_none
    if (cke && !cs_n) begin
      case ({ras_n, cas_n, we_n})
        3'b000: begin  // MRS
          cl = int'(a[6:4]);
          mode_set = 1;
          if (a[2:0] != 0) err("BL не 1");
        end
        3'b011: begin  // ACT
          if (open_[ba]) err($sformatf("ACT в открытый банк %0d", ba));
          row[ba] = a;
          open_[ba] = 1;
          act_t[ba] = $time;
        end
        3'b101, 3'b100: begin  // READ / WRITE
          int addr;
          if (!mode_set) err("доступ до MRS");
          if (!open_[ba]) err($sformatf("доступ в закрытый банк %0d", ba));
          if ($time - act_t[ba] < TRcd) err($sformatf("tRCD %0t", $time - act_t[ba]));
          addr = int'({ba, row[ba], a[7:0]});
          if (we_n) rpipe[cl-2] = addr;  // данные выходят после фронта k+CL−1, верны на k+CL
          else begin
            logic [31:0] old;
            old = mem.exists(addr[20:0]) ? mem[addr[20:0]] : 32'h0;
            for (int b = 0; b < 4; b++) if (!dqm[b]) old[8*b+:8] = dq[8*b+:8];
            mem[addr[20:0]] = old;
          end
          if (a[10]) open_[ba] = 0;
        end
        3'b010: begin  // PRE
          if (a[10]) open_ = '{0, 0, 0, 0};
          else open_[ba] = 0;
        end
        3'b001: begin  // REF
          if (open_[0] || open_[1] || open_[2] || open_[3]) err("REF при открытой строке");
        end
        default: ;
      endcase
    end
  end

endmodule
