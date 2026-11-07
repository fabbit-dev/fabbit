`default_nettype none

// NES machine without physical SDRAM, preserving the existing NESTang mapping.
// This boundary exposes TWO native byte memory ports with FIXED timing: it is
// NOT valid/ready and cannot be connected to a variable-latency controller without
// a proved scheduler/core clock-enable scheme. Existing nes_sdram is the reference.
// CPU/PPU addresses retain their cart.sv semantics (PRG/CHR/RAM windows); no remap here.
// External wrapper holds reset while loading memory and supplies mapper_flags from
// the existing iNES GameLoader. This module alone is not a file loader/profile.
module retro_nes_core (
    input  wire        clk,
    input  wire        reset,
    input  wire [63:0] mapper_flags,
    input  wire [7:0] joy,
    output wire [21:0] cpu_addr,
    output wire        cpu_read,
    output wire        cpu_write,
    output wire [7:0] cpu_wdata,
    input  wire [7:0] cpu_rdata,
    output wire [21:0] ppu_addr,
    output wire        ppu_read,
    output wire        ppu_write,
    output wire [7:0] ppu_wdata,
    input  wire [7:0] ppu_rdata,
    output wire [5:0] color,
    output wire [2:0] emphasis,
    output wire [8:0] cycle,
    output wire [8:0] scanline,
    output wire [15:0] sample
);
  wire [2:0] joypad_out;
  wire [1:0] joypad_clock;
  logic [7:0] joy_shift = '0;
  logic joy_clk_d = 1'b0;
  always_ff @(posedge clk) begin
    joy_clk_d <= joypad_clock[0];
    if (reset) joy_shift <= '0;
    else if (joypad_out[0]) joy_shift <= joy;
    else if (!joypad_clock[0] && joy_clk_d) joy_shift <= {1'b1, joy_shift[7:1]};
  end
  NES machine (
      .clk(clk), .reset_nes(reset), .cold_reset(1'b0), .sys_type(2'b00), .nes_div(),
      .mapper_flags(mapper_flags), .sample(sample), .color(color),
      .joypad_out(joypad_out), .joypad_clock(joypad_clock),
      .joypad1_data({4'b0000, joy_shift[0]}), .joypad2_data(5'b00000),
      .fds_busy(1'b0), .fds_eject(1'b0), .diskside_req(), .diskside(2'b00),
      .audio_channels(5'b11111),
      .cpumem_addr(cpu_addr), .cpumem_read(cpu_read), .cpumem_write(cpu_write),
      .cpumem_dout(cpu_wdata), .cpumem_din(cpu_rdata),
      .ppumem_addr(ppu_addr), .ppumem_read(ppu_read), .ppumem_write(ppu_write),
      .ppumem_dout(ppu_wdata), .ppumem_din(ppu_rdata),
      .bram_addr(), .bram_din(8'h00), .bram_dout(), .bram_write(), .bram_override(),
      .cycle(cycle), .scanline(scanline), .int_audio(1'b1), .ext_audio(1'b0), .apu_ce(),
      .gg(1'b0), .gg_code(129'd0), .gg_avail(), .gg_reset(1'b0), .emphasis(emphasis),
      .save_written());
endmodule

`default_nettype wire
