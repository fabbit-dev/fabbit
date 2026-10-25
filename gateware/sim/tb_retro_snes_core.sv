// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps
module tb_retro_snes_core;
    logic clk = 0;
    always #5 clk = !clk;
    logic reset = 1, console_reset = 0, run = 0;
    logic [1:0] cfg_map = 0;
    logic [7:0] cfg_chip = 0;
    logic cfg_pal = 0;
    logic [21:0] cfg_rom_mask = 22'h007fff;
    logic cfg_save_enable = 1;
    logic [16:0] cfg_save_mask = 17'h01fff;
    logic [11:0] pad1 = 0, pad2 = 0;
    logic ipl_clear = 0, ipl_we = 0;
    logic [5:0] ipl_addr = 0;
    logic [7:0] ipl_data = 0;
    wire ipl_ready;
    logic coeff_clear = 0, coeff_we = 0;
    logic [8:0] coeff_addr = 0;
    logic [11:0] coeff_data = 0;
    wire coeff_ready, active;
    wire [4:0] unsupported;
    wire [16:0] wram_addr, save_addr;
    wire [15:0] aram_addr;
    wire [21:0] rom_addr;
    wire [7:0] wram_data, save_data, aram_data;
    wire wram_rd, wram_wr, aram_rd, aram_wr, rom_rd, save_rd, save_wr;
    logic [7:0] wram_q = 0, save_q = 0, aram_q = 0, rom_q = 0;
    wire sysclk_f_ce, sysclk_r_ce, refresh;
    wire [14:0] rgb;
    wire pixel_ce, dotclk, hs, vs, hde, vde, highres, field, interlace, v224;
    wire [8:0] x, y;
    wire signed [15:0] audio_l, audio_r;
    wire audio_ready;
    snes_console dut (.*);

    logic [7:0] rom [32768];
    logic [7:0] wram [131072];
    logic [7:0] aram [65536];
    logic [7:0] save [131072];
    int use_hirom;
    logic [3:0] dma_seen = 0;
    bit seen_wram = 0, seen_save = 0, seen_apu = 0, seen_aram = 0;
    int audio_count = 0, pixel_count = 0;
    logic [7:0] wram_pipe, save_pipe, aram_pipe, rom_pipe;
    always @(posedge clk) begin
        // Exercise the wrapper's stated two-edge read completion bound.
        rom_q <= rom_pipe;
        wram_q <= wram_pipe;
        save_q <= save_pipe;
        aram_q <= aram_pipe;
        if (rom_rd) rom_pipe <= rom[rom_addr[14:0]];
        if (wram_rd) wram_pipe <= wram[wram_addr];
        if (wram_wr) begin
            wram[wram_addr] <= wram_data;
            if (wram_addr == 0 && wram_data == 8'ha5) seen_wram <= 1;
            if (wram_addr == 1 && wram_data == 8'h5a) seen_apu <= 1;
            if (wram_addr >= 256 && wram_addr < 260 &&
                wram_data == 8'h11 * (8'(wram_addr - 256) + 1))
                dma_seen[wram_addr-256] <= 1;
        end
        if (save_rd) save_pipe <= save[save_addr];
        if (save_wr) begin
            save[save_addr] <= save_data;
            if (save_addr == 16 && save_data == 8'hc3) seen_save <= 1;
        end
        if (aram_rd) aram_pipe <= aram[aram_addr];
        if (aram_wr) begin
            aram[aram_addr] <= aram_data;
            if (aram_addr == 16'h1234 && aram_data == 8'h5a) seen_aram <= 1;
        end
        if (audio_ready) audio_count <= audio_count + 1;
        if (pixel_ce) pixel_count <= pixel_count + 1;
    end
    task automatic tick;
        @(posedge clk); #1;
    endtask

    // Independent PPU memory contract probes.
    logic ven = 0;
    logic [15:0] va = 0, vb = 0;
    logic [7:0] vda = 0, vdb = 0;
    logic vwa_n = 1, vwb_n = 1;
    wire [7:0] vqa, vqb;
    snes_vram probe (.clk, .enable(ven), .addr_a(va), .addr_b(vb),
        .data_a(vda), .data_b(vdb), .we_a_n(vwa_n), .we_b_n(vwb_n), .q_a(vqa), .q_b(vqb));

    logic [11:0] buttons = 0;
    logic latch = 0, serial_clk = 1;
    wire [1:0] serial_data;
    snes_pad pad_probe (.clk, .reset, .buttons, .latch, .serial_clk, .serial_data);

    logic [7:0] oa=0;
    logic [6:0] ob=0;
    logic [15:0] oda=0;
    logic [31:0] odb=0;
    logic owa=0, owb=0;
    wire [15:0] oqa;
    wire [31:0] oqb;
    ppuoam oam_probe (.clock(clk), .address_a(oa), .address_b(ob), .data_a(oda),
        .data_b(odb), .wren_a(owa), .wren_b(owb), .q_a(oqa), .q_b(oqb));
    logic [7:0] caa=0, cab=0;
    logic [14:0] cda=0, cdb=0;
    logic cwa=0, cwb=0;
    wire [14:0] cqa, cqb;
    ppucgram cgram_probe (.clock(clk), .address_a(caa), .address_b(cab),
        .data_a(cda), .data_b(cdb), .wren_a(cwa), .wren_b(cwb), .q_a(cqa), .q_b(cqb));

    logic map_hi = 0, map_enable = 1, map_save_enable = 1;
    logic [21:0] map_rom_mask = 22'h3fffff;
    logic [16:0] map_save_mask = 17'h1ffff;
    logic [23:0] map_cpu_addr = 0;
    logic [7:0] map_cpu_data = 8'h56;
    logic map_rd_n = 0, map_wr_n = 1, map_romsel_n = 0, map_ce = 0;
    wire [7:0] map_cart_data, map_save_data;
    wire [21:0] map_rom_addr;
    wire [16:0] map_save_addr;
    wire map_rom_rd, map_save_rd, map_save_wr;
    snes_cart cart_probe (.clk, .reset, .enable(map_enable), .hirom(map_hi),
        .rom_mask(map_rom_mask), .save_enable(map_save_enable),
        .save_mask(map_save_mask), .cpu_addr(map_cpu_addr), .cpu_data(map_cpu_data),
        .cpu_rd_cycle_n(map_rd_n), .cpu_wr_n(map_wr_n), .romsel_n(map_romsel_n),
        .sysclk_r_ce(map_ce), .cart_data(map_cart_data), .rom_addr(map_rom_addr),
        .rom_rd(map_rom_rd), .rom_q(8'h12), .save_addr(map_save_addr),
        .save_data(map_save_data), .save_rd(map_save_rd), .save_wr(map_save_wr),
        .save_q(8'h34));

    // Original synthetic 65C816 program, not a game dump. Exercises two
    // independent CPU write targets and reads a value from synthetic SPC code.
    byte program_bytes [] = '{
        8'h78, 8'h18, 8'hfb, 8'he2, 8'h20,
        8'ha9, 8'h0f, 8'h8d, 8'h00, 8'h21,
        8'ha9, 8'ha5, 8'h8f, 8'h00, 8'h00, 8'h7e,
        8'ha9, 8'hc3, 8'h8f, 8'h10, 8'h00, 8'h70,
        8'had, 8'h40, 8'h21, 8'hc9, 8'h5a, 8'hd0, 8'hf9,
        8'h8f, 8'h01, 8'h00, 8'h7e,
        // Request BG/OBJ interlace; wrapper must report and remain progressive.
        8'ha9, 8'h03, 8'h8d, 8'h33, 8'h21,
        // High-resolution mode 5 must actually reach wrapper HIGH_RES output.
        8'ha9, 8'h05, 8'h8d, 8'h05, 8'h21,
        // DMA ROM $00:8100 -> $2180 WRAM data port, 4 bytes -> WRAM $100.
        8'ha9, 8'h00, 8'h8d, 8'h81, 8'h21,
        8'ha9, 8'h01, 8'h8d, 8'h82, 8'h21,
        8'ha9, 8'h00, 8'h8d, 8'h83, 8'h21,
        8'h8d, 8'h00, 8'h43,
        8'ha9, 8'h80, 8'h8d, 8'h01, 8'h43,
        8'ha9, 8'h00, 8'h8d, 8'h02, 8'h43,
        8'ha9, 8'h81, 8'h8d, 8'h03, 8'h43,
        8'ha9, 8'h00, 8'h8d, 8'h04, 8'h43,
        8'ha9, 8'h04, 8'h8d, 8'h05, 8'h43,
        8'ha9, 8'h00, 8'h8d, 8'h06, 8'h43,
        8'ha9, 8'h01, 8'h8d, 8'h0b, 8'h42,
        8'h80, 8'hfe
    };
    function automatic byte synthetic_ipl(int addr);
        // MOV A,#$5A; MOV $1234,A; MOV A,$1234; MOV $F4,A; BRA self.
        // Original 12-byte synthetic SPC700 program; vector=$FFC0.
        case (addr)
            0: return 8'he8;
            1: return 8'h5a;
            2: return 8'hc5;
            3: return 8'h34;
            4: return 8'h12;
            5: return 8'he5;
            6: return 8'h34;
            7: return 8'h12;
            8: return 8'hc4;
            9: return 8'hf4;
            10: return 8'h2f;
            11: return 8'hfe;
            62: return 8'hc0;
            63: return 8'hff;
            default: return 8'h00;
        endcase
    endfunction

    initial begin
        for (int i=0; i<32768; i++) rom[i] = 8'hea;
        for (int i=0; i<program_bytes.size(); i++) rom[i] = program_bytes[i];
        if (!$value$plusargs("hirom=%d", use_hirom)) use_hirom=0;
        if (use_hirom != 0) begin
            rom[20] = 8'h60;
            rom[21] = 8'h20;
        end
        rom[32764] = 8'h00;
        rom[32765] = 8'h80;
        rom[256]=8'h11; rom[257]=8'h22; rom[258]=8'h33; rom[259]=8'h44;
        repeat (4) tick();
        reset = 0;
        run = 1;
        tick();
        assert (!active && !ipl_ready && !coeff_ready)
            else $fatal(1,"uninitialized assets enabled core");
        run = 0;
        // Duplicate writes must not satisfy completeness.
        ipl_we = 1;
        repeat (64) tick();
        assert (!ipl_ready) else $fatal(1,"duplicate asset writes accepted as image");
        for (int i=0; i<64; i++) begin
            ipl_addr = 6'(i); ipl_data = synthetic_ipl(i); tick();
        end
        ipl_we = 0;
        assert (ipl_ready && !coeff_ready) else $fatal(1,"IPL readiness");
        coeff_we = 1;
        for (int i=0; i<512; i++) begin
            coeff_addr = 9'(i); coeff_data = 12'(i); tick();
        end
        coeff_we = 0;
        assert (coeff_ready) else $fatal(1,"coefficient readiness");
        // Explicit CPU byte address mapping; no game/header heuristic.
        map_cpu_addr=24'h008000; #1;
        assert (map_rom_rd && map_rom_addr==0 && map_cart_data==8'h12)
            else $fatal(1,"LoROM first bank");
        map_cpu_addr=24'h018000; #1;
        assert (map_rom_addr==22'h008000) else $fatal(1,"LoROM bank stride");
        map_cpu_addr=24'h818000; #1;
        assert (map_rom_addr==22'h008000) else $fatal(1,"LoROM bank mirror");
        map_cpu_addr=24'h700010; map_wr_n=0; #1;
        assert (!map_rom_rd && map_save_wr && map_save_addr==16 && map_save_data==8'h56)
            else $fatal(1,"LoROM save lane");
        map_cpu_addr=24'h728010; #1;
        assert (map_rom_rd && !map_save_wr) else $fatal(1,"LoROM upper ROM");
        map_wr_n=1; map_hi=1; map_cpu_addr=24'hc08000; #1;
        assert (map_rom_addr==22'h008000 && map_rom_rd) else $fatal(1,"HiROM full bank");
        map_cpu_addr=24'h206010; #1;
        assert (!map_rom_rd && map_save_rd && map_save_addr==16 && map_cart_data==8'h34)
            else $fatal(1,"HiROM save window");
        map_cpu_addr=24'ha16010; #1;
        assert (map_save_addr==17'h02010) else $fatal(1,"HiROM save bank mirror");
        map_romsel_n=1; map_cpu_addr=24'h002000; #1;
        assert (!map_rom_rd && !map_save_rd) else $fatal(1,"internal IO cart select");
        // VRAM independent bank addresses, one-cycle read, bit15 wrap.
        ven=1; va=16'h0012; vb=16'h2345; vda=8'h9a; vdb=8'hbc; vwa_n=0; vwb_n=0;
        tick(); vwa_n=1; vwb_n=1; tick();
        assert (vqa==8'h9a && vqb==8'hbc) else $fatal(1,"VRAM lanes/latency");
        va=16'h8012; vb=16'ha345; tick();
        assert (vqa==8'h9a && vqb==8'hbc) else $fatal(1,"VRAM bit15 mirror");
        oa=2; ob=1; oda=16'h1234; owa=1; tick();
        oa=3; oda=16'habcd; tick(); owa=0; tick();
        assert (oqb==32'habcd1234 && oqa==16'habcd)
            else $fatal(1,"OAM mixed-width read/lane");
        oa=2; tick();
        assert (oqa==16'h1234) else $fatal(1,"OAM even lane");
        ob=5; odb=32'hfedc9876; owb=1; tick(); owb=0; oa=10; tick();
        assert (oqa==16'h9876 && oqb==32'hfedc9876)
            else $fatal(1,"OAM port B write");
        caa=17; cab=33; cda=15'h1234; cdb=15'h4567; cwa=1; cwb=1; tick();
        cwa=0; cwb=0; tick();
        assert (cqa==15'h1234 && cqb==15'h4567) else $fatal(1,"CGRAM dual port");
        caa=33; cab=17; tick();
        assert (cqa==15'h4567 && cqb==15'h1234) else $fatal(1,"CGRAM cross port");
        buttons=12'ha59; latch=1; tick(); latch=0;
        for (int i=0; i<16; i++) begin
            assert (serial_data[1] && serial_data[0] == (i<12 ? !buttons[i] : 1'b1))
                else $fatal(1,"pad bit %0d",i);
            serial_clk=0; tick(); serial_clk=1; tick();
        end
        cfg_chip=1; run=1; tick();
        assert (!active && unsupported[1]) else $fatal(1,"chip rejection");
        cfg_chip=0; cfg_map=2; tick();
        assert (!active && unsupported[0]) else $fatal(1,"map rejection");
        cfg_map=0; cfg_pal=1; tick();
        assert (!active && unsupported[2]) else $fatal(1,"PAL rejection");
        cfg_pal=0;
        cfg_map=use_hirom != 0 ? 1 : 0;
        tick();
        assert (active) else $fatal(1,"programmed core not enabled");
        repeat (100000) tick();
        assert (seen_wram && seen_save && seen_apu && seen_aram)
            else $fatal(1,"CPU/APU: WRAM=%b save=%b APU=%b ARAM=%b",
                        seen_wram,seen_save,seen_apu,seen_aram);
        assert (&dma_seen) else $fatal(1,"ROM->WRAM DMA %b",dma_seen);
        assert (audio_count > 0 && pixel_count > 1000 && !interlace &&
                unsupported[3] && highres) else $fatal(1,"native A/V/unsupported mode status");
        run=0; tick();
        assert (!(rom_rd || save_rd || save_wr || wram_rd || wram_wr || aram_rd || aram_wr))
            else $fatal(1,"paused memory side effect");
        console_reset=1; tick(); console_reset=0;
        assert (ipl_ready && coeff_ready) else $fatal(1,"console reset destroyed assets");
        ipl_clear=1; tick(); ipl_clear=0; run=1; tick();
        assert (!ipl_ready && !active) else $fatal(1,"asset clear not fail-closed");
        $display("PASS synthetic CPU/SPC/DMA, VRAM, pad, assets; NO REAL IPL/GAME BOOT CLAIM");
        $display("audio=%0d pixels=%0d hirom=%0d",audio_count,pixel_count,use_hirom);
        $finish;
    end
endmodule
