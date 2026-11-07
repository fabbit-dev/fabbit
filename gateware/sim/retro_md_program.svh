// SPDX-License-Identifier: GPL-3.0-or-later
// Self-authored synthetic 68000/Z80 instructions, not a game ROM or console BIOS.
// Included inside tb_retro_md. Populate only the SDRAM model before execution;
// all running CPU accesses still traverse the adapter, lanes, controller and DQ.

logic [15:0] program_words[$];

task automatic emit_word(input logic [15:0] value, input logic [23:0] address);
  // MOVE.W #value,(address).L
  program_words.push_back(16'h33FC);
  program_words.push_back(value);
  program_words.push_back({8'b0, address[23:16]});
  program_words.push_back(address[15:0]);
endtask

task automatic emit_byte(input logic [7:0] value, input logic [23:0] address);
  // MOVE.B #value,(address).L
  program_words.push_back(16'h13FC);
  program_words.push_back({8'b0, value});
  program_words.push_back({8'b0, address[23:16]});
  program_words.push_back(address[15:0]);
endtask

task automatic emit_copy(input logic [23:0] source, input logic [23:0] destination);
  // MOVE.W (source).L,D0; MOVE.W D0,(destination).L
  program_words.push_back(16'h3039);
  program_words.push_back({8'b0, source[23:16]});
  program_words.push_back(source[15:0]);
  program_words.push_back(16'h33C0);
  program_words.push_back({8'b0, destination[23:16]});
  program_words.push_back(destination[15:0]);
endtask

task automatic init_program;
  logic [7:0] z80_program[22] = '{
      8'h3E, 8'h80, 8'h32, 8'h11, 8'h7F,  // LD A,80; LD (7F11),A: PSG tone latch
      8'h3E, 8'h08, 8'h32, 8'h11, 8'h7F,  // LD A,08; LD (7F11),A: tone period
      8'h3E, 8'h90, 8'h32, 8'h11, 8'h7F,  // LD A,90; LD (7F11),A: volume
      8'h3E, 8'h5A, 8'h32, 8'h00, 8'h01,  // LD A,5A; LD (0100),A: RAM marker
      8'h18, 8'hFE};                       // JR $
  logic [31:0] packed_word;
  // Model-only preload, not a ROM loader test. First raw byte is lane 0.
  for (int i = 0; i < 2048; i++) model.mem[21'(i)] = 0;
  for (int i = 0; i < 16384; i++) model.mem[21'h100000 + 21'(i)] = 0;
  model.mem[21'h000000] = 32'h0000FF00;  // initial SP = 00FF0000
  model.mem[21'h000001] = 32'h00010000;  // reset PC = 00000100
  emit_word(16'h1234, 24'hFF0000);
  emit_byte(8'hAB, 24'hFF0000);
  emit_byte(8'hCD, 24'hFF0001);
  emit_copy(24'hFF0000, 24'hFF0002);  // word + even/odd byte-lane readback
  emit_copy(24'hA10000, 24'hFF0004);  // Americas/NTSC version = A0A0
  emit_word(16'h0100, 24'hA11100);    // acquire Z80 bus
  emit_word(16'h0100, 24'hA11200);    // deassert Z80 reset while bus held
  foreach (z80_program[i]) emit_byte(z80_program[i], 24'hA00000 + 24'(i));
  emit_word(16'h0000, 24'hA11100);    // release Z80 to run uploaded code
  emit_word(16'h8144, 24'hC00004);    // display enable
  emit_word(16'h8C81, 24'hC00004);    // 320x224 mode
  emit_word(16'h8700, 24'hC00004);    // background colour index 0
  emit_word(16'hC000, 24'hC00004);    // CRAM write command
  emit_word(16'h0000, 24'hC00004);
  emit_word(16'h000E, 24'hC00000);    // colour 0 red
  emit_word(16'h8F02, 24'hC00004);    // VRAM auto increment 2 bytes
  emit_word(16'h4000, 24'hC00004);    // VRAM write command at address 0
  emit_word(16'h0000, 24'hC00004);
  emit_word(16'h1357, 24'hC00000);
  emit_word(16'h2468, 24'hC00000);
  emit_word(16'h0000, 24'hC00004);    // VRAM read command at address 0
  emit_word(16'h0000, 24'hC00004);
  emit_copy(24'hC00000, 24'hFF0008);
  emit_copy(24'hC00000, 24'hFF000A);
  program_words.push_back(16'h303C); // MOVE.W #256,D0
  program_words.push_back(16'h0100);
  program_words.push_back(16'h51C8); // DBRA D0,$: wait for Z80 marker
  program_words.push_back(16'hFFFE);
  emit_word(16'h0100, 24'hA11100);    // reacquire Z80 bus
  emit_copy(24'hA00100, 24'hFF0006);  // marker = 5A5A (8-bit bus replicated)
  program_words.push_back(16'h60FE); // BRA $: loop
  // Pad to a physical 32-bit word; unreachable after BRA $.
  if (program_words.size() % 2 != 0) program_words.push_back(16'h4E71);
  assert (program_words.size() < 3968)
      else $fatal(1, "synthetic program length");
  for (int i = 0; i < program_words.size(); i += 2) begin
    packed_word = {program_words[i+1][7:0], program_words[i+1][15:8],
                   program_words[i][7:0], program_words[i][15:8]};
    model.mem[21'h000040 + 21'(i/2)] = packed_word;
  end
endtask
