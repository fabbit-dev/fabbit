// SPDX-License-Identifier: GPL-3.0-or-later
// Plain LoROM/HiROM subset of SNESTang's DSP_LHRomMap mapping.
// No enhancement-chip RTL, firmware, RTC or EEPROM is instantiated.
// Masks are size-1 for power-of-two, headerless, already normalized images.
// Non-power-of-two ROM mirroring must be normalized by the loader, not guessed.
module snes_cart (
    input logic clk,
    input logic reset,
    input logic enable,
    input logic hirom,
    input logic [21:0] rom_mask,
    input logic save_enable,
    input logic [16:0] save_mask,
    input logic [23:0] cpu_addr,
    input logic [7:0] cpu_data,
    input logic cpu_rd_cycle_n,
    input logic cpu_wr_n,
    input logic romsel_n,
    input logic sysclk_r_ce,
    output logic [7:0] cart_data,
    output logic [21:0] rom_addr,
    output logic rom_rd,
    input logic [7:0] rom_q,
    output logic [16:0] save_addr,
    output logic [7:0] save_data,
    output logic save_rd,
    output logic save_wr,
    input logic [7:0] save_q
);
    logic save_select, no_save_select;
    logic [7:0] open_bus;
    always_comb begin
        save_select = 1'b0;
        no_save_select = 1'b0;
        if (hirom) begin
            rom_addr = cpu_addr[21:0] & rom_mask;
            save_addr = {cpu_addr[19:16], cpu_addr[12:0]} & save_mask;
            save_select = cpu_addr[22:21] == 2'b01 &&
                          cpu_addr[15:13] == 3'b011 && save_enable;
        end else begin
            rom_addr = {cpu_addr[22:16], cpu_addr[14:0]} & rom_mask;
            // Conventional LoROM SRAM is bank concatenated with A[14:0].
            save_addr = {cpu_addr[17:16], cpu_addr[14:0]} & save_mask;
            if (cpu_addr[22:20] == 3'b111 && !romsel_n) begin
                if (rom_mask[20] || (save_enable && save_mask[15])) begin
                    save_select = !cpu_addr[15] && save_enable;
                    no_save_select = !cpu_addr[15] && !save_enable;
                end else begin
                    save_addr = cpu_addr[16:0] & save_mask;
                    save_select = save_enable;
                    no_save_select = !cpu_addr[15] && !save_enable;
                end
            end
        end
        rom_rd = enable && !romsel_n && !save_select && !no_save_select && !cpu_rd_cycle_n;
        save_rd = enable && save_select && !cpu_rd_cycle_n;
        save_wr = enable && save_select && !cpu_wr_n;
        save_data = cpu_data;
        cart_data = save_select ? save_q :
                    (!romsel_n && !no_save_select) ? rom_q : open_bus;
    end
    always_ff @(posedge clk) begin
        if (reset) open_bus <= 8'hff;
        else if (enable && sysclk_r_ce) open_bus <= cpu_data;
    end
endmodule
