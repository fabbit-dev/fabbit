`default_nettype none
`timescale 1ns / 1ps

// Real managed NES, owned SDRAM controller and upstream-authored nes15 ROM.
// +start_offset=N delays LOAD by N nclk edges to vary loader/slot alignment.
// +buffer_test=1 substitutes an authored ROM exercising buffered CPU $2007 reads.
// +negative_consumer=cpu|dma|ppu_bg|ppu_sprite|ppu_buffer corrupts only the checker sample.
module tb_retro_nes_render;
  // realtime avoids rounding this 15.556ns period to 16ns in a time variable.
  localparam realtime Tf = 15.556ns;
  localparam logic [31:0] ExpectedCrc = 32'h6d6dd387;
  logic fclk = 0, nclk = 0, model_clk = 0;
  always #(Tf / 2) fclk = ~fclk;
  initial begin
    #14500ps;
    forever #(Tf / 2) model_clk = ~model_clk;
  end
  int div = 0;
  always @(posedge fclk) begin
    div <= (div == 2) ? 0 : div + 1;
    if (div == 0) nclk <= 1;
    if (div == 1) nclk <= 0;
  end

  logic [7:0] rom [1 << 20];
  int rom_len = 0, rom_pos = 0;
  bit buffer_test = 0;
  int buffer_cpu_reads = 0, buffer_marker_writes = 0;
  logic rst = 1, load_go = 0, run_enable = 0;
  wire rom_ready, loading, done, fail, reset_nes, memory_busy, fb_we;
  wire rom_valid = loading && rom_pos < rom_len;
  wire [7:0] fb_x, fb_y;
  wire [8:0] fb_d, scanline;
  wire sd_clk, ras_n, cas_n, we_n, dq_drive;
  wire [10:0] sd_a;
  wire [1:0] sd_ba;
  wire [31:0] sd_dq, dq_output;
  assign sd_dq = dq_drive ? dq_output : 'z;
  always @(posedge nclk) if (rom_ready) rom_pos <= rom_pos + 1;

  nes_system #(.Managed(1'b1), .SplitDq(1'b1)) dut (
      .nclk(nclk), .fclk(fclk), .sdram_clk_in(model_clk), .rst(rst), .load_go(load_go),
      .reset_go(1'b0), .rom_valid(rom_valid), .rom_ready(rom_ready), .rom_data(rom[rom_pos]),
      .joy(8'h00), .loading(loading), .loader_done(done), .loader_fail(fail),
      .reset_nes(reset_nes), .fb_we(fb_we), .fb_x(fb_x), .fb_y(fb_y), .fb_d(fb_d),
      .sample(), .scanline(scanline), .sdram_clk(sd_clk), .sdram_a(sd_a), .sdram_ba(sd_ba),
      .sdram_ras_n(ras_n), .sdram_cas_n(cas_n), .sdram_we_n(we_n), .sdram_dq(),
      .core_freeze(1'b0), .run_enable(run_enable), .memory_busy(memory_busy),
      .dq_input(sd_dq), .dq_output(dq_output), .dq_drive(dq_drive));

  sdram_model #(.DynamicCasTiming(1'b1), .TOh(2ns), .TRcd(21ns)) model (
      .clk(sd_clk), .cke(1'b1), .cs_n(1'b0), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
      .ba(sd_ba), .a(sd_a), .dqm(4'b0000), .dq(sd_dq));

  // Observe physical commands, not the controller's internal schedule. Keep
  // picosecond resolution: four fclk periods (62.224ns) must fail tRFC63ns.
  realtime last_ref = -1us;
  realtime last_act [4] = '{-1us, -1us, -1us, -1us};
  realtime min_trfc = 1s, min_trcd = 1s;
  int refreshes = 0, run_refreshes = 0, accesses = 0;
  logic [10:0] observed_row [4];
  always @(posedge sd_clk) begin
    if ({ras_n, cas_n, we_n} != 3'b111) begin
      if (refreshes != 0) begin
        if ($realtime - last_ref < 63ns)
          $fatal(1, "pin tRFC %0.3fns <63ns, command %b",
                 ($realtime - last_ref) / 1ns, {ras_n, cas_n, we_n});
        if ($realtime - last_ref < min_trfc) min_trfc = $realtime - last_ref;
      end
      case ({ras_n, cas_n, we_n})
        3'b011: begin
          last_act[sd_ba] = $realtime;
          observed_row[sd_ba] = sd_a;
        end
        3'b100, 3'b101: begin
          accesses++;
          if ($realtime - last_act[sd_ba] < 21ns)
            $fatal(1, "pin tRCD %0.3fns <21ns, bank %0d",
                   ($realtime - last_act[sd_ba]) / 1ns, sd_ba);
          if ($realtime - last_act[sd_ba] < min_trcd)
            min_trcd = $realtime - last_act[sd_ba];
          // Decode the physical WRITE pins independently of controller state.
          // NES CPU $0000 maps to physical word $0E0000, byte lane zero.
          if (buffer_test && run_enable && !reset_nes && !we_n &&
              {sd_ba, observed_row[sd_ba], sd_a[7:0]} == 21'h0e0000) begin
            if (sd_dq[7:0] !== 8'h5a)
              $fatal(1, "buffer WRAM physical marker expected=5a observed=%h", sd_dq[7:0]);
            buffer_marker_writes++;
          end
        end
        3'b001: begin
          refreshes++;
          if (run_enable) run_refreshes++;
          last_ref = $realtime;
        end
        default: ;
      endcase
    end
  end

  logic [8:0] fb [256 * 240];
  logic [8:0] line_d = 0;
  int frames = 0;
  always @(posedge nclk) begin
    if (run_enable && !reset_nes && fb_we) fb[{fb_y, fb_x}] = fb_d;
    line_d <= scanline;
    if (run_enable && !reset_nes && scanline == 9'd240 && line_d == 9'd239)
      frames <= frames + 1;
  end

  function automatic logic [31:0] crc32(input logic [31:0] crc, input logic [7:0] b);
    crc = crc ^ 32'(b);
    for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (32'hEDB88320 & -(crc & 1));
    return crc;
  endfunction

  // Consumer-boundary scoreboard. No controller slots/capture registers are
  // consulted. nes.v:277/288 clocks T65 DI on cpu_ce; :309/316 clocks DMA;
  // :458/462 clocks mapper conflict data on cart_ce. ppu.v:506-527 samples
  // background bytes on odd cycles, SpriteSet samples pattern bytes at 5/7,
  // and :897-900 clocks the delayed $2007 read into vram_latch.
  // Independently spell out nes_sdram's byte->word remap. DQM is grounded,
  // so byte lane zero of the physical model word is the expected NES byte.
  function automatic bit [20:0] physical_word(input logic [21:0] address);
    if (!address[21]) return {2'b00, address[18:0]};
    if (!address[20]) return {3'b010, address[17:0]};
    return {3'b011, address[19:18], address[15:0]};
  endfunction

  typedef struct packed {
    bit valid;
    bit initialized;
    logic [21:0] address;
    logic [7:0] expected;
  } read_ticket_t;
  read_ticket_t cpu_ticket, ppu_ticket;
  bit cpu_read_old = 0, ppu_read_old = 0;
  int cpu_checks = 0, dma_checks = 0, conflict_checks = 0;
  int ppu_bg_checks = 0, ppu_sprite_checks = 0, ppu_buffer_checks = 0;
  int cpu_uninitialized = 0, ppu_uninitialized = 0, mapper_chr_skips = 0;
  string negative_consumer;
  bit negative_injected = 0;
  initial void'($value$plusargs("negative_consumer=%s", negative_consumer));

  task automatic snapshot(input logic [21:0] address, output read_ticket_t ticket);
    bit [20:0] word_address;
    word_address = physical_word(address);
    ticket.valid = 1;
    ticket.address = address;
    ticket.initialized = model.mem.exists(word_address) != 0;
    ticket.expected = ticket.initialized ? model.mem[word_address][7:0] : 8'h00;
    // Missing RAM is power-on state, not a defined return value. Missing ROM
    // is a loading/remapping error and must not silently disappear as a skip.
    if (!ticket.initialized && address[21:20] != 2'b11)
      $fatal(1, "consumer requested absent ROM: NES=%h physical=%h", address, word_address);
  endtask

  // Requests originate at nclk posedges. The intervening falling edge sees
  // stable address/read outputs and snapshots expected data before consumption.
  always @(negedge nclk) begin
    if (!run_enable || reset_nes) begin
      cpu_ticket.valid = 0;
      ppu_ticket.valid = 0;
      cpu_read_old = 0;
      ppu_read_old = 0;
    end else begin
      if (dut.cpu_rd && !cpu_read_old) snapshot(dut.cpu_addr, cpu_ticket);
      if (dut.ppu_rd && !ppu_read_old) snapshot(dut.ppu_addr, ppu_ticket);
      cpu_read_old = dut.cpu_rd;
      ppu_read_old = dut.ppu_rd;
    end
  end

  task automatic consume(input read_ticket_t ticket, input logic [7:0] observed,
                         input string consumer, input bit cpu_side);
    logic [7:0] checked_value;
    if (!ticket.valid) $fatal(1, "%s consumed without a request snapshot", consumer);
    if (!ticket.initialized) begin
      if (cpu_side) cpu_uninitialized++;
      else ppu_uninitialized++;
      return;
    end
    checked_value = observed;
    // Checker-only negative control: production return and machine state are
    // unchanged. Each consumer family can independently prove its assertion.
    if (!negative_injected && negative_consumer == consumer) begin
      checked_value ^= 8'h01;
      negative_injected = 1;
      $display("negative control: corrupting observed %s return only", consumer);
    end
    if (checked_value !== ticket.expected)
      $fatal(1, "%s deadline/value: NES=%h expected=%h observed=%h at %0t",
             consumer, ticket.address, ticket.expected, checked_value, $time);
    case (consumer)
      "cpu": cpu_checks++;
      "dma": dma_checks++;
      "conflict": conflict_checks++;
      "ppu_bg": ppu_bg_checks++;
      "ppu_sprite": ppu_sprite_checks++;
      "ppu_buffer": ppu_buffer_checks++;
      default: $fatal(1, "unknown consumer %s", consumer);
    endcase
  endtask

  // Pre-NBA sampling is intentional: these are the same input values used by
  // each consumer's sequential block, not values captured later by SDRAM.
  always @(posedge nclk) if (run_enable && !reset_nes) begin
    if (buffer_test && dut.u_nes.cpu_ce && !dut.u_nes.pause_cpu &&
        !dut.u_nes.dma_aout_enable && dut.u_nes.mr_int &&
        dut.u_nes.addr == 16'h2007) begin
      buffer_cpu_reads++;
      // The first read primes the buffer; T65 must consume its value on the second.
      if (buffer_cpu_reads == 2 && dut.u_nes.cpu.DI !== 8'h5a)
        $fatal(1, "buffer CPU $2007 expected=5a observed=%h", dut.u_nes.cpu.DI);
    end
    if (dut.u_nes.cpu_ce && dut.u_nes.mr_int && dut.u_nes.prg_allow &&
        !dut.u_nes.apu_cs && !dut.u_nes.ppu_cs) begin
      // At reset exit T65 can clock its initial RAM address before its first
      // prefetch. Only an absent power-on RAM word has no defined value here.
      if ((!cpu_ticket.valid || cpu_ticket.address !== dut.cpu_addr) &&
          dut.cpu_addr[21:20] == 2'b11 &&
          !model.mem.exists(physical_word(dut.cpu_addr))) cpu_uninitialized++;
      else begin
        if (cpu_ticket.address !== dut.cpu_addr)
          $fatal(1, "CPU request address changed: snapshot=%h current=%h valid=%b cpu_addr=%h",
                 cpu_ticket.address, dut.cpu_addr, cpu_ticket.valid, dut.u_nes.addr);
        if (dut.u_nes.dma_aout_enable)
          consume(cpu_ticket, dut.u_nes.dma.data_from_ram, "dma", 1);
        else if (!dut.u_nes.pause_cpu)
          consume(cpu_ticket, dut.u_nes.cpu.DI, "cpu", 1);
      end
    end
    if (dut.u_nes.cart_ce && dut.u_nes.prg_write && dut.u_nes.prg_conflict) begin
      read_ticket_t conflict_ticket;
      conflict_ticket = cpu_ticket;
      conflict_ticket.expected &= dut.u_nes.dbus;
      consume(conflict_ticket, dut.u_nes.multi_mapper.prg_din, "conflict", 1);
    end
    if (dut.u_nes.ppu_ce) begin
      if (dut.u_nes.ppu.is_rendering && dut.u_nes.ppu.cycle[0]) begin
        if (dut.u_nes.has_chr_from_ppu_mapper) mapper_chr_skips++;
        else begin
          // LoopyGen can change the live address on the request CE (notably
          // horizontal reload at256). Compare the sampled request, not that
          // subsequent live address.
          // Name/attribute data also reaches BgPainter in the sprite window;
          // bitmap fetches in that window feed SpriteSet instead.
          if (dut.u_nes.ppu.cycle[8] && !dut.u_nes.ppu.cycle[6] &&
              dut.u_nes.ppu.cycle[2])
            consume(ppu_ticket, dut.u_nes.ppu.vram_din, "ppu_sprite", 0);
          else consume(ppu_ticket, dut.u_nes.ppu.vram_din, "ppu_bg", 0);
        end
      end
      if (dut.u_nes.ppu.vram_read_delayed) begin
        if (dut.u_nes.has_chr_from_ppu_mapper) mapper_chr_skips++;
        else consume(ppu_ticket, dut.u_nes.ppu.vram_din, "ppu_buffer", 0);
      end
    end
  end

  task automatic make_buffer_rom;
    logic [7:0] program_bytes [54] = '{
      8'h78, 8'hd8,                         // SEI; CLD
      8'ha9, 8'h00, 8'h8d, 8'h00, 8'h20,   // PPUCTRL=0 (increment 1, NMI off)
      8'h8d, 8'h01, 8'h20,                 // PPUMASK=0 (rendering off)
      8'had, 8'h02, 8'h20,                 // reset PPU address latch
      8'ha9, 8'h20, 8'h8d, 8'h06, 8'h20,
      8'ha9, 8'h00, 8'h8d, 8'h06, 8'h20,   // PPUADDR=$2000
      8'ha9, 8'h5a, 8'h8d, 8'h07, 8'h20,   // VRAM[$2000]=$5A
      8'ha9, 8'ha5, 8'h8d, 8'h07, 8'h20,   // VRAM[$2001]=$A5: second refill defined
      8'ha9, 8'h20, 8'h8d, 8'h06, 8'h20,
      8'ha9, 8'h00, 8'h8d, 8'h06, 8'h20,   // PPUADDR=$2000 again
      8'had, 8'h07, 8'h20,                 // dummy read; buffer loads $5A
      8'had, 8'h07, 8'h20,                 // CPU reads $5A; buffer loads $A5
      8'h85, 8'h00,                       // physical WRAM marker at $0000
      8'h4c, 8'h33, 8'h80                  // JMP $8033
    };
    rom_len = 16 + 16384 + 8192;
    for (int i = 0; i < rom_len; i++) rom[i] = 0;
    rom[0] = 8'h4e; rom[1] = 8'h45; rom[2] = 8'h53; rom[3] = 8'h1a;
    rom[4] = 1; rom[5] = 1; // NROM-128 with 8 KiB CHR ROM
    for (int i = 0; i < 16384; i++) rom[16 + i] = 8'hea;
    foreach (program_bytes[i]) rom[16 + i] = program_bytes[i];
    for (int i = 16 + 16384 - 6; i < 16 + 16384; i += 2) begin
      rom[i] = 8'h00;
      rom[i + 1] = 8'h80;
    end
  endtask

  initial begin
    string rom_file;
    int fd, colors, start_offset;
    logic [31:0] crc;
    bit seen [512];
    start_offset = 0;
    void'($value$plusargs("start_offset=%d", start_offset));
    if (start_offset < 0) $fatal(1, "start_offset must be nonnegative");
    void'($value$plusargs("buffer_test=%d", buffer_test));
    if (buffer_test) begin
      rom_file = "authored buffered $2007 NROM-128";
      make_buffer_rom();
    end else begin
      if (!$value$plusargs("rom=%s", rom_file)) rom_file = "profiles/nes/core/src/roms/nes15.hex";
      fd = $fopen(rom_file, "r");
      if (fd == 0) $fatal(1, "cannot open ROM %s", rom_file);
      while (rom_len < (1 << 20) && $fscanf(fd, "%h", rom[rom_len]) == 1) rom_len++;
      $fclose(fd);
    end
    $display("ROM %s: %0d bytes, start_offset=%0d", rom_file, rom_len, start_offset);

    repeat (10) @(negedge nclk);
    rst = 0;
    wait (!memory_busy);
    repeat (start_offset) @(negedge nclk);
    @(negedge nclk) load_go = 1;
    @(negedge nclk) load_go = 0;
    wait (loading);
    wait (!loading);
    @(negedge nclk);
    if (!done || fail || rom_pos != 16 + 16384 * int'(rom[4]) + 8192 * int'(rom[5]))
      $fatal(1, "ROM load failed: done=%b fail=%b consumed=%0d", done, fail, rom_pos);
    $display("ok ROM loaded: %0d bytes", rom_pos);

    // Do not reset/reinitialize SDRAM or rephase clkref at COMMIT. Let the
    // loader's write stretching and final physical transaction fully drain.
    repeat (200) @(negedge nclk);
    if (!reset_nes || memory_busy || fail || !done)
      $fatal(1, "managed machine did not remain ready and held before COMMIT");
    run_enable = 1;
    $display("ok COMMIT after 200 nclk drain edges");
    wait (!reset_nes);
    if (buffer_test) begin
      wait (buffer_marker_writes != 0 && buffer_cpu_reads >= 2);
      repeat (20) @(negedge nclk);
      if (buffer_cpu_reads != 2 || ppu_buffer_checks != 2 || buffer_marker_writes != 1)
        $fatal(1, "buffer coverage CPU_reads=%0d refills=%0d physical_markers=%0d",
               buffer_cpu_reads, ppu_buffer_checks, buffer_marker_writes);
      if (ppu_uninitialized != 0 || mapper_chr_skips != 0)
        $fatal(1, "buffer PPU skips: uninitialized=%0d mapper_CHR=%0d",
               ppu_uninitialized, mapper_chr_skips);
      if (!model.mem.exists(21'h0e0000) || model.mem[21'h0e0000][7:0] !== 8'h5a)
        $fatal(1, "buffer WRAM marker not stored in physical SDRAM");
      if (negative_consumer != "")
        $fatal(1, "negative control did not reach consumer %s", negative_consumer);
      if (model.errors != 0) $fatal(1, "SDRAM model errors: %0d", model.errors);
      $display("buffer consumers: CPU_reads=%0d ppu_buffer=%0d physical_markers=%0d",
               buffer_cpu_reads, ppu_buffer_checks, buffer_marker_writes);
      $display("buffer PPU skips: uninitialized=%0d mapper_CHR=%0d",
               ppu_uninitialized, mapper_chr_skips);
      $display("SDRAM: model.errors=%0d min_tRFC=%0.3fns min_tRCD=%0.3fns",
               model.errors, min_trfc / 1ns, min_trcd / 1ns);
      $display("ok managed split-DQ NES buffered $2007 CPU read and physical WRAM marker 5a");
      $finish;
    end
    wait (frames == 4);
    @(negedge nclk);
    crc = '1;
    colors = 0;
    foreach (fb[i]) begin
      crc = crc32(crc, fb[i][7:0]);
      crc = crc32(crc, {7'd0, fb[i][8]});
      if (!seen[fb[i]]) begin
        seen[fb[i]] = 1;
        colors++;
      end
    end
    $display("frame %0d: CRC %08h, colors %0d", frames, ~crc, colors);
    $display("SDRAM: model.errors=%0d refreshes=%0d run_refreshes=%0d accesses=%0d",
             model.errors, refreshes, run_refreshes, accesses);
    $display("SDRAM: min_tRFC=%0.3fns min_tRCD=%0.3fns", min_trfc / 1ns, min_trcd / 1ns);
    $display("consumers: cpu=%0d dma=%0d conflict=%0d ppu_bg=%0d ppu_sprite=%0d ppu_buffer=%0d",
             cpu_checks, dma_checks, conflict_checks, ppu_bg_checks, ppu_sprite_checks,
             ppu_buffer_checks);
    $display("consumer skips: uninitialized CPU=%0d PPU=%0d mapper_CHR=%0d",
             cpu_uninitialized, ppu_uninitialized, mapper_chr_skips);
    if (cpu_checks == 0 || ppu_bg_checks == 0 || ppu_sprite_checks == 0)
      $fatal(1, "missing CPU/background/sprite consumer coverage");
    if (negative_consumer != "")
      $fatal(1, "negative control did not reach consumer %s", negative_consumer);
    if (~crc != ExpectedCrc) $fatal(1, "frame CRC %08h != baseline %08h", ~crc, ExpectedCrc);
    if (colors <= 1) $fatal(1, "frame must contain more than one color");
    if (run_refreshes == 0 || accesses == 0) $fatal(1, "no runtime SDRAM refresh/access");
    if (model.errors != 0) $fatal(1, "SDRAM model errors: %0d", model.errors);
    $display("ok managed split-DQ NES four-frame render and strict SDRAM timing");
    $finish;
  end

  initial begin
    #100ms;
    $fatal(1, "timeout: loading=%b done=%b fail=%b frames=%0d bytes=%0d", loading, done,
           fail, frames, rom_pos);
  end
endmodule
