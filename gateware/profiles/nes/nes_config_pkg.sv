// Конфигурация ядра NESTang под Colorlight i9+ и его SDRAM M12L64322A (2M×32 = 8 МБ:
// 4 банка, строка 11 бит, столбец 8 бит) — та же геометрия, что у Tang Nano 20K.
// Читается первым: пакет configPackage нужен sdram_nes.v, а NANO включает в нём 32-битную шину
// (без него столбец берётся как addr[9:1] и бит 9 адреса теряется).
`ifndef NANO
`define NANO
`endif

// имена заданы ядром (import configPackage::*), поэтому стиль verible здесь не действует
// verilog_lint: waive-start package-filename
// verilog_lint: waive-start parameter-name-style
package configPackage;
  localparam int SDRAM_DATA_WIDTH = 32;
  localparam int SDRAM_ROW_WIDTH = 11;
  localparam int SDRAM_COL_WIDTH = 8;
  localparam int SDRAM_BANK_WIDTH = 2;
endpackage
// verilog_lint: waive-stop parameter-name-style
// verilog_lint: waive-stop package-filename
