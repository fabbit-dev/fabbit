`default_nettype none

// Система NES без привязки к плате: загрузчик ROM, ядро NESTang, память на SDRAM и выход кадра
// в виде записей пикселей. Верх профиля (nes_top) даёт такты, шину ESP и видеотракт; тест
// (sim/tb_nes.sv) подаёт ROM и модель SDRAM.
module nes_system (
    input  wire        nclk,         // 21,43 МГц
    input  wire        fclk,         // 3 × nclk, синфазно
    input  wire        sdram_clk_in, // fclk со сдвигом фазы
    input  wire        rst,          // сброс домена nclk
    input  wire        load_go,      // импульс: начать загрузку ROM
    input  wire        reset_go,     // импульс: сбросить ядро
    // поток ROM (файл .nes целиком)
    input  wire        rom_valid,
    output logic       rom_ready = 1'b0,
    input  wire  [7:0] rom_data,
    input  wire  [7:0] joy,          // A, B, Select, Start, Вверх, Вниз, Влево, Вправо
    output logic       loading = 1'b0,
    output wire        loader_done,
    output wire        loader_fail,
    output logic       reset_nes = 1'b1,
    // пиксели кадра 256×240: {emphasis, color}
    output logic       fb_we = 1'b0,
    output logic [7:0] fb_x = '0,
    output logic [7:0] fb_y = '0,
    output logic [8:0] fb_d = '0,
    output wire  [15:0] sample,
    output wire  [8:0] scanline,
    // SDRAM
    output wire        sdram_clk,
    output wire [10:0] sdram_a,
    output wire  [1:0] sdram_ba,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    inout  wire [31:0] sdram_dq
);
  // ---- загрузка ROM (как nestang_top: запись растянута на 2 такта, байт не чаще раза в 4 такта,
  //      чтобы каждая запись попала в своё окно clkref контроллера SDRAM) ----
  logic clkref_sync = 1'b0;
  logic [1:0] pace = '0;
  logic [9:0] rst_hold = '0;  // сброс ядра по команде: 1024 такта
  logic in_clk = 1'b0;
  logic [7:0] in_data = '0;
  wire [21:0] loader_addr;
  wire [7:0] loader_wdata;
  wire loader_write;
  wire [63:0] loader_flags;
  logic [63:0] mapper_flags = '0;
  logic loader_write_r = 1'b0, loader_write_mem = 1'b0;
  logic [21:0] loader_addr_mem = '0;
  logic [7:0] loader_wdata_mem = '0;
  // GameLoader снимает error только с первым байтом заголовка: после неудачной загрузки (мусор на
  // шине при перезапуске ESP) старый error оборвал бы новую загрузку на первом такте
  logic got_byte = 1'b0;

  always_ff @(posedge nclk) begin
    in_clk      <= 1'b0;
    rom_ready   <= 1'b0;
    clkref_sync <= 1'b0;
    if (pace != 0) pace <= pace - 1'b1;
    if (loading && rom_valid && pace == 0 && !rom_ready) begin
      rom_ready <= 1'b1;  // байт забран этим тактом
      in_clk    <= 1'b1;
      in_data   <= rom_data;
      pace      <= 2'd3;
    end
    loader_write_r   <= loader_write;
    loader_write_mem <= loader_write || loader_write_r;
    if (loader_write) begin
      loader_addr_mem  <= loader_addr;
      loader_wdata_mem <= loader_wdata;
    end
    if (in_clk) got_byte <= 1'b1;
    if (rst) begin
      loading   <= 1'b0;
      reset_nes <= 1'b1;
    end else if (load_go) begin
      loading   <= 1'b1;
      reset_nes <= 1'b1;
      got_byte  <= 1'b0;
    end else if (loading && got_byte && (loader_done || loader_fail)) begin
      loading      <= 1'b0;
      reset_nes    <= loader_fail;
      clkref_sync  <= 1'b1;  // ядро стартует в начале окна clkref, как в nestang_top
      mapper_flags <= loader_flags;
    end else if (reset_go) begin
      reset_nes <= 1'b1;
      rst_hold  <= '1;
    end else if (rst_hold != 0) begin
      rst_hold <= rst_hold - 1'b1;
      if (rst_hold == 10'd1 && loader_done) begin
        reset_nes   <= 1'b0;
        clkref_sync <= 1'b1;
      end
    end
  end

  GameLoader u_loader (
      .clk(nclk), .reset(rst || load_go), .downloading(loading),
      .filetype(8'b0000_0010), .is_bios(1'b0), .invert_mirroring(1'b0),
      .indata(in_data), .indata_clk(in_clk),
      .mem_addr(loader_addr), .mem_data(loader_wdata), .mem_write(loader_write),
      .bios_download(), .mapper_flags(loader_flags), .busy(), .done(loader_done),
      .error(loader_fail), .rom_loaded());

  // ---- ядро ----
  wire [5:0] color;
  wire [2:0] emphasis;
  wire [8:0] cycle;
  wire [2:0] joypad_out;
  wire [1:0] joypad_clock;
  wire [21:0] cpu_addr, ppu_addr;
  wire cpu_rd, cpu_wr, ppu_rd, ppu_wr;
  wire [7:0] cpu_dout, ppu_dout, cpu_din, ppu_din;
  logic [7:0] joy_sh = '0;
  logic joy_clk_d = 1'b0;

  NES u_nes (
      .clk(nclk), .reset_nes(reset_nes), .cold_reset(1'b0), .sys_type(2'b00), .nes_div(),
      .mapper_flags(mapper_flags), .sample(sample), .color(color),
      .joypad_out(joypad_out), .joypad_clock(joypad_clock),
      .joypad1_data({4'b0, joy_sh[0]}), .joypad2_data(5'b0),
      .fds_busy(1'b0), .fds_eject(1'b0), .diskside_req(), .diskside(2'b00),
      .audio_channels(5'b11111),
      .cpumem_addr(cpu_addr), .cpumem_read(cpu_rd), .cpumem_write(cpu_wr),
      .cpumem_dout(cpu_dout), .cpumem_din(cpu_din),
      .ppumem_addr(ppu_addr), .ppumem_read(ppu_rd), .ppumem_write(ppu_wr),
      .ppumem_dout(ppu_dout), .ppumem_din(ppu_din),
      .bram_addr(), .bram_din(8'h00), .bram_dout(), .bram_write(), .bram_override(),
      .cycle(cycle), .scanline(scanline), .int_audio(1'b1), .ext_audio(1'b0), .apu_ce(),
      .gg(1'b0), .gg_code(129'd0), .gg_avail(), .gg_reset(1'b0), .emphasis(emphasis),
      .save_written());

  // джойстик: регистр сдвига 4021, как у nestang_top (кнопки защёлкиваются стробом)
  always_ff @(posedge nclk) begin
    joy_clk_d <= joypad_clock[0];
    if (joypad_out[0]) joy_sh <= joy;
    else if (!joypad_clock[0] && joy_clk_d) joy_sh <= {1'b1, joy_sh[7:1]};
  end

  // ---- память ----
  wire mem_busy, clkref;
  nes_sdram u_mem (
      .clk(nclk), .fclk(fclk), .sdram_clk(sdram_clk_in), .rst(rst), .clkref_sync(clkref_sync),
      .clkref(clkref), .busy(mem_busy),
      .addr_a(ppu_addr), .oe_a(ppu_rd), .we_a(ppu_wr), .din_a(ppu_dout), .dout_a(ppu_din),
      .addr_b(loading ? loader_addr_mem : cpu_addr), .oe_b(!loading && cpu_rd),
      .we_b(loader_write_mem || cpu_wr), .din_b(loading ? loader_wdata_mem : cpu_dout),
      .dout_b(cpu_din),
      .sd_clk(sdram_clk), .sd_a(sdram_a), .sd_ba(sdram_ba), .sd_ras_n(sdram_ras_n),
      .sd_cas_n(sdram_cas_n), .sd_we_n(sdram_we_n), .sd_dq(sdram_dq));


  // пиксель PPU меняется раз в 4 такта ядра: пишем при смене координаты
  logic [8:0] cyc_d = '0, line_d = '0;
  always_ff @(posedge nclk) begin
    cyc_d  <= cycle;
    line_d <= scanline;
    fb_we  <= (cycle != cyc_d || scanline != line_d) && scanline < 9'd240 && !cycle[8];
    fb_x   <= cycle[7:0];
    fb_y   <= scanline[7:0];
    fb_d   <= {emphasis, color};
  end

endmodule
