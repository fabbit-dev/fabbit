#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "rom_cart.h"

static void put_be32(uint8_t *p, uint32_t x)
{
    p[0] = x >> 24; p[1] = x >> 16; p[2] = x >> 8; p[3] = x;
}
static void snes(uint8_t *h, bool high)
{
    memset(h, 0, 64);
    memcpy(h, "SYNTHETIC CART TEST   ", 21);
    h[0x15] = high ? 0x21 : 0x20;
    h[0x17] = 6;  // 64 KiB
    h[0x19] = 1;
    h[0x1C] = 0xCB; h[0x1D] = 0xED;
    h[0x1E] = 0x34; h[0x1F] = 0x12;
    h[0x3D] = 0x80;
}
int main(void)
{
    uint8_t md[512] = {0};
    memcpy(md + 0x100, "SEGA MEGA DRIVE ", 16);
    put_be32(md, 0xFFFF00);
    put_be32(md + 4, 0x200);
    put_be32(md + 0x1A4, 65535);
    md[0x1F0] = 'U';
    rom_md_info_t mi;
    assert(rom_parse_md(md, 512, 65536, &mi) == ROM_CART_OK);
    assert(mi.payload_size == 65536 && mi.reset_pc == 512 && !mi.sram);
    memcpy(md + 0x1B0, "RA", 2);
    md[0x1B2] = 0xf8;
    put_be32(md + 0x1B4, 0); put_be32(md + 0x1B8, 1);
    assert(rom_parse_md(md, 512, 65536, &mi) == ROM_CART_UNSUPPORTED && !mi.payload_size);
    put_be32(md + 0x1B4, 0x200001); put_be32(md + 0x1B8, 0x203fff);
    assert(rom_parse_md(md, 512, 65536, &mi) == ROM_CART_OK && mi.sram);
    assert(mi.ram_size == 8192);
    put_be32(md + 0x1B8, 0x220001);
    assert(rom_parse_md(md, 512, 65536, &mi) == ROM_CART_UNSUPPORTED);
    put_be32(md + 0x1B4, 0x200000); put_be32(md + 0x1B8, 0x21ffff);
    assert(rom_parse_md(md, 512, 65536, &mi) == ROM_CART_OK && mi.ram_size == 131072);
    md[0x1B2] = 0xe8; // serial EEPROM is not linear SRAM
    assert(rom_parse_md(md, 512, 65536, &mi) == ROM_CART_UNSUPPORTED && !mi.payload_size);
    md[0x1B2] = 0xf8;
    memcpy(md + 0x120, "VIRTUA RACING", 13);
    assert(rom_parse_md(md, 512, 65536, &mi) == ROM_CART_UNSUPPORTED);
    memset(md + 0x120, 0, 13);
    for (size_t i = 0; i < 512; i++)
        assert(rom_parse_md(md, i, 65536, &mi) == ROM_CART_INVALID && !mi.payload_size);
    assert(rom_parse_md(NULL, 512, 65536, &mi) == ROM_CART_INVALID);
    assert(rom_parse_md(md, 512, UINT64_MAX, &mi) != ROM_CART_OK);
    assert(rom_parse_md(md, 512, 65535, &mi) == ROM_CART_INVALID);
    put_be32(md + 4, 0x201);
    assert(rom_parse_md(md, 512, 65536, &mi) == ROM_CART_INVALID);
    put_be32(md + 4, 65536);
    assert(rom_parse_md(md, 512, 65536, &mi) == ROM_CART_INVALID);
    put_be32(md + 4, 0x200);
    md[0x1F0] = 'E';
    assert(rom_parse_md(md, 512, 65536, &mi) == ROM_CART_UNSUPPORTED);
    md[0x1F0] = 'U';
    memcpy(md + 0x100, "SEGA 32X", 8);
    assert(rom_parse_md(md, 512, 65536, &mi) == ROM_CART_UNSUPPORTED);
    uint8_t lo[64], hi[64] = {0};
    snes(lo, false);
    rom_snes_info_t si;
    assert(rom_parse_snes(lo, 64, hi, 64, 65536, &si) == ROM_CART_OK);
    assert(si.map == ROM_SNES_LOROM && si.payload_size == 65536 && !si.payload_offset);
    assert(!memcmp(si.header, lo, 64));
    assert(rom_parse_snes(lo, 64, hi, 64, 66048, &si) == ROM_CART_OK);
    assert(si.payload_offset == 512 && si.payload_size == 65536);
    for (size_t i = 0; i < 64; i++)
        assert(rom_parse_snes(lo, i, NULL, 0, 65536, &si) == ROM_CART_INVALID);
    assert(rom_parse_snes(lo, 64, hi, 64, 65535, &si) == ROM_CART_INVALID);
    assert(rom_parse_snes(lo, 64, hi, 64, UINT64_MAX, &si) != ROM_CART_OK);
    assert(rom_parse_snes(lo, 64, hi, 64, 8 * 1024 * 1024, &si) == ROM_CART_UNSUPPORTED);
    assert(rom_parse_snes(lo, 64, hi, 64, 3 * 1024 * 1024, &si) == ROM_CART_UNSUPPORTED);
    snes(hi, true);
    assert(rom_parse_snes(lo, 64, hi, 64, 65536, &si) == ROM_CART_AMBIGUOUS);
    memset(lo, 0, sizeof lo);
    hi[0x15] = 0x31; hi[0x16] = 2; hi[0x18] = 5;
    assert(rom_parse_snes(lo, 64, hi, 64, 65536, &si) == ROM_CART_OK);
    assert(si.map == ROM_SNES_HIROM && si.fast_rom && si.ram_size == 32768);
    hi[0x16] = 3;
    assert(rom_parse_snes(lo, 64, hi, 64, 65536, &si) == ROM_CART_UNSUPPORTED);
    hi[0x16] = 0; hi[0x18] = 0; hi[0x19] = 2;
    assert(rom_parse_snes(lo, 64, hi, 64, 65536, &si) == ROM_CART_UNSUPPORTED);
    hi[0x19] = 1; hi[0x17] = 255;
    assert(rom_parse_snes(lo, 64, hi, 64, 65536, &si) == ROM_CART_UNSUPPORTED);
    hi[0x17] = 5;
    assert(rom_parse_snes(lo, 64, hi, 64, 65536, &si) == ROM_CART_INVALID);
    hi[0x17] = 6; hi[0x1E] ^= 1;
    assert(rom_parse_snes(lo, 64, hi, 64, 65536, &si) == ROM_CART_INVALID);
    assert(!si.payload_size && !si.ram_size);
    assert(rom_parse_md(md, 512, 65536, NULL) == ROM_CART_INVALID);
    assert(rom_parse_snes(NULL, 0, NULL, 0, 65536, NULL) == ROM_CART_INVALID);
    // Deterministic fuzz of untrusted header bytes and 64-bit file sizes.
    uint32_t random = 0x71A35D89u;
    for (int i = 0; i < 20000; i++) {
        random ^= random << 13; random ^= random >> 17; random ^= random << 5;
        md[random % sizeof md] = random >> 24;
        lo[random % sizeof lo] = random >> 16;
        hi[(random >> 8) % sizeof hi] = random >> 8;
        uint64_t size = i & 1 ? (uint64_t)random << 32 | random : random % (8 * 1024 * 1024);
        rom_cart_result_t mr = rom_parse_md(md, random % 513, size, &mi);
        rom_cart_result_t sr = rom_parse_snes(lo, random % 65, hi, (random >> 8) % 65, size, &si);
        if (mr == ROM_CART_OK) assert(mi.payload_size <= 4 * 1024 * 1024);
        else assert(!mi.payload_size);
        if (sr == ROM_CART_OK) assert(si.payload_size <= 4 * 1024 * 1024 && si.payload_offset <= 512);
        else assert(!si.payload_size);
    }
    puts("ok carts: canonical MD endian/vectors, SNES maps/copier prefix, ambiguous/unsupported/bounds");
    return 0;
}
