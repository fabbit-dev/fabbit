#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rom.h"

// Oracle: прежняя policy GameLoader, независимо от нового parser.
static bool legacy(const uint8_t h[16], rom_nes_info_t *info)
{
    if (memcmp(h, "NES\x1a", 4) || !h[4] || h[4] > 32 || h[5] > 32 || (h[6] & 4) ||
        ((h[7] & 0x0C) != 0 && (h[7] & 0x0C) != 8) ||
        ((h[7] & 0x0C) == 8 && h[9])) return false;
    info->mapper = (h[6] >> 4) | (h[7] & 0xF0);
    if ((h[7] & 0x0C) != 8) {
        bool dirty = (h[9] & 0xFE) != 0;
        for (int i = 10; i < 16; i++) dirty |= h[i] != 0;
        if (dirty) info->mapper = h[6] >> 4;
    }
    info->prg_kb = h[4] * 16;
    info->chr_kb = h[5] * 8;
    info->need = 16 + h[4] * 16384u + h[5] * 8192u;
    return true;
}

static void parity(const uint8_t h[16])
{
    rom_nes_info_t old = {0}, now = {0};
    bool ok = legacy(h, &old);
    assert(rom_parse_nes(h, 16, &now) == ok);
    if (ok) {
        assert(old.mapper == now.mapper && old.prg_kb == now.prg_kb &&
               old.chr_kb == now.chr_kb && old.need == now.need);
    } else {
        assert(!now.mapper && !now.prg_kb && !now.chr_kb && !now.need);
    }
}

int main(void)
{
    uint8_t h[16] = {'N', 'E', 'S', 0x1A, 1};
    rom_nes_info_t nes;
    for (size_t n = 0; n < 16; n++) {
        // ASan проверяет, что parser не читает недостающие байты.
        uint8_t *short_h = n ? malloc(n) : NULL;
        assert(!n || short_h);
        if (n) memcpy(short_h, h, n);
        assert(!rom_parse_nes(short_h, n, &nes));
        free(short_h);
    }
    assert(!rom_parse_nes(NULL, 16, &nes));
    assert(!rom_parse_nes(h, 16, NULL));
    for (int prg = 0; prg <= 33; prg++) {
        for (int chr = 0; chr <= 33; chr++) {
            h[4] = prg; h[5] = chr;
            for (int flags = 0; flags < 256; flags++) {
                h[7] = flags;
                h[6] = 0xA0; h[9] = 0; h[15] = 0; parity(h);
                h[6] |= 4; parity(h);  // trainer
                h[6] &= ~4; h[9] = 1; parity(h);  // NES2 extended size
                h[9] = 2; h[15] = 1; parity(h);  // dirty header
            }
        }
    }
    memset(h, 0, sizeof h);
    memcpy(h, "NES\x1a", 4); h[4] = 1;
    rom_info_t info;
    assert(rom_probe(h, 16, 16400, "cart.bin", &info) == ROM_OK);
    assert(info.system == ROM_NES && info.payload_offset == 0 && info.payload_size == 16400);
    assert(info.nes.need == 16400 && info.nes.prg_kb == 16 && !info.nes.chr_kb);
    h[7] = 8;
    h[8] = 4;
    assert(rom_probe(h, 16, 16400, "mapper.nes", &info) == ROM_UNAVAILABLE);
    assert(!info.payload_size);
    h[8] = 0;
    for (int console = 1; console <= 3; console++) {
        h[7] = 8 | console;
        assert(rom_probe(h, 16, 16400, "console.nes", &info) == ROM_UNAVAILABLE);
    }
    h[7] = 8; h[12] = 1;
    assert(rom_probe(h, 16, 16400, "pal.nes", &info) == ROM_UNAVAILABLE);
    h[12] = 0;
    assert(rom_probe(h, 16, 16400, "ntsc.nes", &info) == ROM_OK);
    h[12] = 2;
    assert(rom_probe(h, 16, 16400, "multi-region.nes", &info) == ROM_OK);
    h[12] = 3;
    assert(rom_probe(h, 16, 16400, "dendy.nes", &info) == ROM_UNAVAILABLE);
    h[12] = 0;
    h[7] = 0;
    h[9] = 1;
    assert(rom_probe(h, 16, 16400, "ines-pal.nes", &info) == ROM_UNAVAILABLE);
    h[9] = 0;
    assert(rom_probe(h, 16, UINT64_MAX, "cart.sfc", &info) == ROM_OK);
    assert(info.payload_size == 16400);  // хвост не входит в wire payload
    assert(rom_probe(h, 16, 16399, "cart.nes", &info) == ROM_INVALID);
    assert(!info.payload_size && !info.nes.need);
    assert(rom_probe(h, 16, 15, NULL, &info) == ROM_INVALID);
    assert(rom_probe(h, 15, 16400, NULL, &info) == ROM_INVALID);
    h[6] = 4;
    assert(rom_probe(h, 16, 16400, "cart.md", &info) == ROM_INVALID);
    assert(info.system == ROM_NES && !info.payload_size);
    memset(h, 0, sizeof h);
    const char *hints[] = {"cart.MD", "/roms/cart.GeN", "cart.SFC", "cart.sMc"};
    for (size_t i = 0; i < sizeof hints / sizeof *hints; i++) {
        assert(rom_probe(h, 16, 65536, hints[i], &info) == ROM_UNAVAILABLE);
        assert(info.system == (i < 2 ? ROM_MD : ROM_SNES));
        assert(!info.payload_size && !info.nes.need);  // hint, не validation
    }
    const char *unknown[] = {"cart.bin", "cart.smd", "cart", "/dir.md/cart", "cart.md.bak", NULL};
    for (size_t i = 0; i < sizeof unknown / sizeof *unknown; i++) {
        assert(rom_probe(h, 16, 65536, unknown[i], &info) == ROM_UNKNOWN);
        assert(info.system == ROM_NONE && !info.payload_size);
    }
    assert(rom_probe(h, 16, 65536, "cart.NeS", &info) == ROM_INVALID);
    assert(rom_probe(NULL, 0, 0, "cart.nes", &info) == ROM_INVALID);
    assert(rom_probe(NULL, 0, 0, NULL, &info) == ROM_UNKNOWN);
    assert(rom_probe(NULL, 16, 16400, NULL, &info) == ROM_INVALID);
    assert(rom_probe(h, 16, 16400, NULL, NULL) == ROM_INVALID);
    puts("ok ROM: NES parser parity, bounds, payload, hints are not backends");
    return 0;
}
