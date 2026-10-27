// SPDX-License-Identifier: GPL-3.0-or-later
// SNESTang machine slice; one static-bitstream constituent, not a profile loader.
// clk = 21.47727 MHz NTSC. All input controls/data are synchronous to clk.
// No physical SDRAM, clock primitive, framebuffer, scaler or HDMI is included.
//
// LOGICAL MEMORY CONTRACT (byte addresses and byte data, no byte enables):
// WRAM: 128 KiB, ARAM: 64 KiB, ROM: <=4 MiB, save: <=128 KiB.
// *_rd/*_wr are LEVEL strobes. Controller must detect first assertion/address
// change; do not enqueue a transaction every clock while a strobe stays high.
// Return read data <=2 clk edges after first observed request, hold until next
// completion. No ready/backpressure exists in this SNESTang machine boundary.
// CPU/HDMA read result needed before SYSCLKR_CE (or the following DMA write);
// shortest CPU bus period = 6 masters, DMA = 8. Read and write may overlap
// (e.g. ROM->WRAM DMA). Preserve read-before-write ordering/data forwarding.
// ARAM result needed by next DSP CE (5 or 6 masters). It is an independent
// concurrent channel; never serialize it behind a CPU multi-cycle bus period.
// 2-channel 3x-master controller option: CPU ROM/WRAM/save one schedule, ARAM
// the other, repeat six fast clocks. Meet above bound INCLUDING arbitration,
// refresh and DQM-grounded byte-write handling; upstream x16/DQM is NOT usable.
// DQM grounded: allocate independent x32 words for writable bytes (or verified
// RMW). Pack read-only ROM if desired. At 4 MiB ROM + 4*(128+64+128) KiB =
// 5.25 MiB total before loader/framebuffer. This is a capacity bound, NOT proof
// of controller timing or combined NES+MD+SNES fit.
//
// reset clears asset validity. Program both assets with run=0 after reset;
// console_reset restarts machine without losing assets. Missing asset/unsupported
// configuration holds machine in reset. No default IPL/coefficient contents.
// Host sets cfg_chip=0 ONLY for plain ROM/RAM/battery carts after header parsing.
// cfg_map: 0 LoROM, 1 HiROM; others rejected. PAL/enhancement chips rejected.
// Progressive enforced in PPU. Interlace writes reported in unsupported[3].
// Configuration is decoded/captured only on stopped (run=0) clock edges;
// allow one such edge after changing it before requesting execution.
module snes_console (
    input logic clk,
    input logic reset,
    input logic console_reset,
    input logic run,
    input logic [1:0] cfg_map,
    input logic [7:0] cfg_chip,
    input logic cfg_pal,
    input logic [21:0] cfg_rom_mask,
    input logic cfg_save_enable,
    input logic [16:0] cfg_save_mask,
    input logic [11:0] pad1, pad2,
    input logic ipl_clear, ipl_we,
    input logic [5:0] ipl_addr,
    input logic [7:0] ipl_data,
    output logic ipl_ready,
    input logic coeff_clear, coeff_we,
    input logic [8:0] coeff_addr,
    input logic [11:0] coeff_data,
    output logic coeff_ready,
    output logic active,
    output logic [4:0] unsupported,
    output logic [16:0] wram_addr,
    output logic [7:0] wram_data,
    output logic wram_rd, wram_wr,
    input logic [7:0] wram_q,
    output logic [15:0] aram_addr,
    output logic [7:0] aram_data,
    output logic aram_rd, aram_wr,
    input logic [7:0] aram_q,
    output logic [21:0] rom_addr,
    output logic rom_rd,
    input logic [7:0] rom_q,
    output logic [16:0] save_addr,
    output logic [7:0] save_data,
    output logic save_rd, save_wr,
    input logic [7:0] save_q,
    output logic sysclk_f_ce, sysclk_r_ce, refresh,
    output logic [14:0] rgb,
    output logic pixel_ce, dotclk,
    output logic hs, vs, hde, vde,
    output logic highres, field, interlace, v224,
    output logic [8:0] x, y,
    output logic signed [15:0] audio_l, audio_r,
    output logic audio_ready
);
    logic [5:0] ipl_read_addr;
    logic [7:0] ipl_read_data;
    logic [8:0] coeff_read_addr;
    logic signed [11:0] coeff_read_data;
    logic interlace_requested;
    logic core_reset;
    logic hirom, save_enable;
    logic [21:0] rom_mask;
    logic [16:0] save_mask;
    logic [3:0] config_bad;
    // Keep mask arithmetic and raw configuration out of the live CPU/SDRAM
    // request cone. These registers remain frozen through run and drain.
    always_ff @(posedge clk) begin
        if (reset) begin
            hirom <= 0;
            save_enable <= 0;
            rom_mask <= 0;
            save_mask <= 0;
            config_bad <= '1;
        end else if (!run) begin
            hirom <= cfg_map[0];
            save_enable <= cfg_save_enable;
            rom_mask <= cfg_rom_mask;
            save_mask <= cfg_save_mask;
            config_bad[0] <= cfg_map > 1;
            config_bad[1] <= cfg_chip != 0;
            config_bad[2] <= cfg_pal;
            config_bad[3] <= ((cfg_rom_mask & (cfg_rom_mask + 22'd1)) != 0) ||
                            cfg_rom_mask[14:0] != 15'h7fff ||
                            (cfg_save_enable &&
                             (((cfg_save_mask & (cfg_save_mask + 17'd1)) != 0) ||
                              cfg_save_mask[10:0] != 11'h7ff));
        end
    end
    assign unsupported[2:0] = config_bad[2:0];
    assign unsupported[3] = interlace_requested;
    assign unsupported[4] = config_bad[3];
    assign active = run && !reset && !console_reset && ipl_ready && coeff_ready &&
                    !(|{unsupported[4], unsupported[2:0]});
    assign core_reset = !active;
    snes_assets assets (.*);

    logic [23:0] ca;
    logic [7:0] cpu_data, cart_data;
    logic cpu_rd_cycle_n, cpu_wr_n, romsel_n;
    logic wram_ce_n, wram_rd_n, wram_we_n;
    logic aram_ce_n, aram_oe_n, aram_we_n;
    logic [15:0] va, vb;
    logic [7:0] vda, vdb, vqa, vqb;
    logic vwa_n, vwb_n;
    logic [1:0] joy1_data, joy2_data;
    logic joy_latch, joy1_clk, joy2_clk;
    logic old_dotclk;

    assign wram_rd = active && !wram_ce_n && !wram_rd_n;
    assign wram_wr = active && !wram_ce_n && !wram_we_n;
    assign aram_rd = active && !aram_ce_n && !aram_oe_n;
    assign aram_wr = active && !aram_ce_n && !aram_we_n;
    // RGB has main/subscreen phases. Sample BOTH dotclk edges (512 samples
    // per visible line). low-res consumers may decimate alternate phases.
    always_ff @(posedge clk) old_dotclk <= dotclk;
    assign pixel_ce = active && (dotclk != old_dotclk);

    snes_pad joy1 (.clk, .reset(core_reset), .buttons(pad1), .latch(joy_latch),
                   .serial_clk(joy1_clk), .serial_data(joy1_data));
    snes_pad joy2 (.clk, .reset(core_reset), .buttons(pad2), .latch(joy_latch),
                   .serial_clk(joy2_clk), .serial_data(joy2_data));
    snes_vram vram (.clk, .enable(active), .addr_a(va), .addr_b(vb),
        .data_a(vda), .data_b(vdb), .we_a_n(vwa_n), .we_b_n(vwb_n),
        .q_a(vqa), .q_b(vqb));
    snes_cart cart (.clk, .reset(core_reset), .enable(active), .hirom,
        .rom_mask, .save_enable, .save_mask,
        .cpu_addr(ca), .cpu_data, .cpu_rd_cycle_n, .cpu_wr_n, .romsel_n,
        .sysclk_r_ce, .cart_data, .rom_addr, .rom_rd, .rom_q,
        .save_addr, .save_data, .save_rd, .save_wr, .save_q);

    SNES machine (
        .MCLK(clk), .RST_N(!core_reset), .ENABLE(active), .PAL(1'b0),
        .BLEND(1'b0), .DIS_SHORTLINE(1'b0),
        .IPL_DATA(ipl_read_data), .IPL_ADDR(ipl_read_addr),
        .COEFF_DATA(coeff_read_data), .COEFF_ADDR(coeff_read_addr),
        .INTERLACE_REQUESTED(interlace_requested),
        .CA(ca), .CPURD_N(), .CPUWR_N(cpu_wr_n), .CPURD_CYC_N(cpu_rd_cycle_n),
        .DOT_CLK_CE(), .PA(), .PARD_N(), .PAWR_N(), .DI(cart_data), .DO(cpu_data),
        .RAMSEL_N(), .ROMSEL_N(romsel_n), .SYSCLKF_CE(sysclk_f_ce),
        .SYSCLKR_CE(sysclk_r_ce), .SNES_REFRESH(refresh), .IRQ_N(1'b1),
        .WRAM_ADDR(wram_addr), .WRAM_D(wram_data), .WRAM_Q(wram_q),
        .WRAM_CE_N(wram_ce_n), .WRAM_OE_N(), .WRAM_WE_N(wram_we_n), .WRAM_RD_N(wram_rd_n),
        .VRAM_ADDRA(va), .VRAM_ADDRB(vb), .VRAM_DAI(vqa), .VRAM_DBI(vqb),
        .VRAM_DAO(vda), .VRAM_DBO(vdb), .VRAM_WRA_N(vwa_n), .VRAM_WRB_N(vwb_n), .VRAM_RD_N(),
        .ARAM_ADDR(aram_addr), .ARAM_D(aram_data), .ARAM_Q(aram_q),
        .ARAM_CE_N(aram_ce_n), .ARAM_OE_N(aram_oe_n), .ARAM_WE_N(aram_we_n),
        .HIGH_RES(highres), .FIELD_OUT(field), .INTERLACE(interlace), .V224_MODE(v224),
        .DOTCLK(dotclk), .RGB_OUT(rgb), .HDE(hde), .VDE(vde), .HSYNC(hs), .VSYNC(vs),
        .X_OUT(x), .Y_OUT(y), .JOY1_DI(joy1_data), .JOY2_DI(joy2_data),
        .JOY_STRB(joy_latch), .JOY1_CLK(joy1_clk), .JOY2_CLK(joy2_clk),
        .AUDIO_L(audio_l), .AUDIO_R(audio_r), .AUDIO_READY(audio_ready), .AUDIO_EN(1'b1),
        .DBG_SEL(8'h00), .DBG_REG(8'h00), .DBG_REG_WR(1'b0), .DBG_DAT_IN(8'h00),
        .DBG_DAT_OUT(), .DBG_BREAK()
    );
endmodule
