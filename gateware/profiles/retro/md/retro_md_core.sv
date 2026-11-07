// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none

// Mega Drive machine boundary, MDTang 903d30cbd92cf03bc31cd55f925d8985e3225f1e.
// FX68K + T80 + VDP + JT12/YM2612 + JT89/PSG; no SVP/CD/32X/EEPROM,
// cheats, multitap, filters or persistent save service in this elaboration.
// Core RAM/VDP internals and upstream notices are retained under rtl/.
//
// CLOCK/RESET: clk_master_i = 53.693175 MHz (NTSC), clk_z80_i = master/2,
// phase-related, NOT asynchronous. Both must run during reset. Constrain their
// real generated-clock relationship, not an asynchronous clock group.
// reset_i is synchronous active-high. Reset adapter ack to zero together with
// this core. Startup: reset_i=1, loading_i=0 for >=32 master edges, then hold
// loading_i=1 for >=16384 master edges to clear 64 KiB VRAM, then drop both.
// WRAM and Z80 RAM are NOT cleared here (console power-on contents undefined).
// ROM loading, size validation and WRAM/save initialisation belong to caller.
//
// MEMORY: one outstanding 16-bit transaction in clk_master_i domain, exactly
// the upstream MEM_REQ/MEM_ACK toggle protocol. req != ack means pending;
// req == ack means complete. NOT pulse-valid/ready. Adapter captures addr,
// we, be and wdata after seeing a mismatch, executes ONCE, supplies rdata and
// copies req to ack. Read data must be valid BEFORE the edge on which the
// core sees equality; keep it until the next completion. Core holds request
// fields through completion, but does not offer a cancel or a separate accept.
// Do not acknowledge early or assert ack for an unexecuted write.
// Upstream MBUS_ROM/RAM/SRAM_READ explicitly wait for equality: these bus
// clients can wait for memory. This is NOT a global clock/VDP stall mechanism;
// no arbitrary-latency guarantee for display DMA or Z80/VDP real-time behavior.
// Upstream controller reference: ~4 memory clocks plus arbitration/refresh.
//
// mem_addr_o[23:0] is a WORD INDEX (upstream MEM_ADDR[24:1]); byte address is
// {mem_addr_o,1'b0}. Big endian: be[1] selects wdata[15:8] at EVEN byte,
// be[0] selects wdata[7:0] at ODD byte; reads always return both bytes.
// Read requests can carry be=00; do NOT mask their returned data by be.
// Logical windows (byte address; NOT i9+ physical SDRAM geometry):
//   000000-3fffff cartridge ROM for this slice, preloaded big-endian raw data;
//   800000-80ffff 64 KiB 68K WRAM (CPU e00000-ffffff mirrors);
//   820000-83ffff 128 KiB VOLATILE cartridge SRAM backing, selected by BANK_SRAM
//                 or upstream fallback 200000-37ffff when outside ROM.
// Restrict ROM to 2..4194304 bytes, even length; rom_words_i = bytes/2,
// stable from reset release until next reset. Reject SVP/EEPROM/CD/32X and
// special carts externally. Upstream Sega bank register logic remains, but
// >4 MiB banked ROM is NOT supported by this contract. SRAM has no disk save.
// Common adapter must preserve untouched byte lanes (DQM is NOT assumed).
// 64 KiB VRAM remains INTERNAL: four 16Kx8 true-dual-port arrays, CPU port
// 16 bits at vram_a[15:1], renderer port 32 bits at vram32_a[15:2]. Both
// synchronous one-master-edge reads, toggle ack on following edge, independent
// byte write enables on CPU port. 8 KiB Z80 RAM also stays internal (1-edge).
// Do not externalise VRAM with the stallable ROM/WRAM protocol.
//
// GENERIC PAD: active high, bits 0..11 = Up,Down,Left,Right,A,B,X,Y,L,R,
// Select,Start. MD A=Y (bit7), MD B=B (bit5), MD C=A (bit4), Start=bit11.
// 3-button mode fixed; X,L,R,Select ignored. Opposite directions neutralised.
// Native RGB444/pixel_ce, active-LOW HS/VS, active-HIGH HDE/VDE. Width/height
// vary (256/320 and 224/240), interlace/field exposed; no HDMI/scaler here.
// resolution_o = {V30,H40}: 00=256x224, 01=320x224, 10=256x240, 11=320x240.
// Stereo signed 16-bit samples, continuously held in master domain; not I2S
// and not 48 kHz sample pulses. Caller handles audio-rate conversion.
module retro_md_core (
    input  wire        clk_master_i,
    input  wire        clk_z80_i,
    input  wire        reset_i,
    input  wire        loading_i,
    input  wire [11:0] pad1_i,
    input  wire [11:0] pad2_i,
    input  wire [23:0] rom_words_i,
    output wire [23:0] mem_addr_o,
    output wire [15:0] mem_wdata_o,
    output wire [1:0]  mem_be_o,
    output wire        mem_we_o,
    output wire        mem_req_o,
    input  wire        mem_ack_i,
    input  wire [15:0] mem_rdata_i,
    output wire [3:0]  red_o,
    output wire [3:0]  green_o,
    output wire [3:0]  blue_o,
    output wire        pixel_ce_o,
    output wire        hs_n_o,
    output wire        vs_n_o,
    output wire        hde_o,
    output wire        vde_o,
    output wire        interlace_o,
    output wire        field_o,
    output wire [1:0]  resolution_o,
    output wire signed [15:0] audio_left_o,
    output wire signed [15:0] audio_right_o,
    output wire [23:0] debug_m68k_addr_o,
    output wire [23:0] debug_vbus_addr_o
);
    function automatic logic [11:0] md_pad(input logic [11:0] p);
        md_pad = {4'b0000, p[11], p[4], p[5], p[7],
                  p[0] & ~p[1], p[1] & ~p[0],
                  p[2] & ~p[3], p[3] & ~p[2]};
    endfunction

    wire hblank, vblank, hs, vs;
    assign hde_o = ~hblank;
    assign vde_o = ~vblank;
    // system inverts the VDP's native active-low syncs.
    assign hs_n_o = ~hs;
    assign vs_n_o = ~vs;
    retro_md_system machine (
        .RESET_N(~(reset_i | loading_i)),
        .MCLK(clk_master_i), .CLK_Z80(clk_z80_i),
        .LPF_MODE(2'b11), .ENABLE_FM(1'b1), .ENABLE_PSG(1'b1),
        .DAC_LDATA(audio_left_o), .DAC_RDATA(audio_right_o),
        .LOADING(loading_i), .PAL(1'b0), .EXPORT(1'b1),
        .FAST_FIFO(1'b0), .SRAM_QUIRK(1'b0), .SRAM00_QUIRK(1'b0),
        .EEPROM_QUIRK(1'b0), .NORAM_QUIRK(1'b0), .PIER_QUIRK(1'b0),
        .SVP_QUIRK(1'b0), .FMBUSY_QUIRK(1'b0), .SCHAN_QUIRK(1'b0),
        .TURBO(2'b00), .GG_RESET(1'b0), .GG_EN(1'b0),
        .GG_CODE(129'b0), .GG_AVAILABLE(),
        .BRAM_A(15'b0), .BRAM_DI(16'b0), .BRAM_WE(1'b0),
        .BRAM_DO(), .BRAM_CHANGE(),
        .RED(red_o), .GREEN(green_o), .BLUE(blue_o),
        .VS(vs), .HS(hs), .HBL(hblank), .VBL(vblank),
        .CE_PIX(pixel_ce_o), .BORDER(1'b0), .CRAM_DOTS(1'b0),
        .INTERLACE(interlace_o), .FIELD(field_o), .RESOLUTION(resolution_o),
        .J3BUT(1'b1), .JOY_1(md_pad(pad1_i)), .JOY_2(md_pad(pad2_i)),
        .JOY_3(12'b0), .JOY_4(12'b0), .JOY_5(12'b0), .MULTITAP(3'b000),
        .MOUSE(25'b0), .MOUSE_OPT(3'b000), .GUN_OPT(1'b0),
        .GUN_TYPE(1'b0), .GUN_SENSOR(1'b0), .GUN_A(1'b0), .GUN_B(1'b0),
        .GUN_C(1'b0), .GUN_START(1'b0), .SERJOYSTICK_IN(8'hFF),
        .SERJOYSTICK_OUT(), .SER_OPT(2'b00),
        .ROMSZ(rom_words_i), .MEM_ADDR(mem_addr_o),
        .MEM_DATA(mem_rdata_i), .MEM_WDATA(mem_wdata_o),
        .MEM_WE(mem_we_o), .MEM_BE(mem_be_o),
        .MEM_REQ(mem_req_o), .MEM_ACK(mem_ack_i),
        .EN_HIFI_PCM(1'b1), .LADDER(1'b0), .OBJ_LIMIT_HIGH(1'b0),
        .TRANSP_DETECT(), .PAUSE_EN(1'b0),
        .BGA_EN(1'b1), .BGB_EN(1'b1), .SPR_EN(1'b1),
        .DBG_M68K_A(debug_m68k_addr_o), .DBG_VBUS_A(debug_vbus_addr_o)
    );
endmodule

`default_nettype wire
