#include "rom_cart.h"

#include <string.h>

static uint32_t be32(const uint8_t *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

rom_cart_result_t rom_parse_md(const uint8_t *h, size_t n, uint64_t size, rom_md_info_t *info)
{
    if (!info) return ROM_CART_INVALID;
    memset(info, 0, sizeof *info);
    if (!h || n < 512 || size < 512 || (size & 1) || memcmp(h + 0x100, "SEGA", 4))
        return ROM_CART_INVALID;
    // The fixture's linear cartridge arena deliberately excludes mapper/SVP/CD/32X modes.
    if (size > 4 * 1024 * 1024 || memcmp(h + 0x100, "SEGA 32X", 8) == 0 ||
        !memcmp(h + 0x100, "SEGA PICO", 9) ||
        !memcmp(h + 0x183, "MK-1229", 7) || !memcmp(h + 0x183, "G-7001", 6) ||
        !memcmp(h + 0x120, "VIRTUA RACING", 13) || !memcmp(h + 0x150, "VIRTUA RACING", 13))
        return ROM_CART_UNSUPPORTED;
    uint32_t sp = be32(h), pc = be32(h + 4);
    uint32_t start = be32(h + 0x1A0), end = be32(h + 0x1A4);
    // 24-bit bus: A31-A24 are not connected, so only SP[23:0] matters. 0 is the top of
    // work RAM (first push lands at 0xFFFFFE): UMK3 0x01000000, Sonic 3 0, Sonic 2 0xFFFFFE00.
    uint32_t sp24 = sp & 0xFFFFFFu;
    if ((sp & 1) || (sp24 != 0 && sp24 < 0xFF0000) ||
        (pc & 1) || pc < 0x200 || pc >= size || start != 0 ||
        end != size - 1) return ROM_CART_INVALID;
    // Initial wrapper runs NTSC Americas; do not infer region from file suffix.
    // Region field: letters (J/U/E) or, in later carts, one flag digit (1 Japan,
    // 4 Americas, 8 Europe). Hex digits A-F are not read as flags: 'E' is Europe.
    bool americas = false;
    for (size_t i = 0x1F0; i < 0x200; i++) americas |= h[i] == 'U';
    uint8_t flags = h[0x1F0];
    if (flags >= '0' && flags <= '9' && (h[0x1F1] == ' ' || h[0x1F1] == 0))
        americas |= ((flags - '0') & 4) != 0;
    if (!americas) return ROM_CART_UNSUPPORTED;
    bool sram = h[0x1B0] == 'R' && h[0x1B1] == 'A';
    uint32_t ram = 0;
    if (sram) {
        uint32_t first = be32(h + 0x1B4), last = be32(h + 0x1B8);
        // The RTL maps cartridge SRAM using CPU byte address bits [16:0].
        // Accept only its first 128 KiB aperture: wider/other header ranges
        // would silently alias or remain ROM. Byte-lane and word SRAM are allowed.
        if (h[0x1B2] != 0xf8 || first < 0x200000 || last < first || last > 0x21ffff ||
            last - first >= 131072) return ROM_CART_UNSUPPORTED;
        ram = last - first + 1;
        if ((first & 1) == (last & 1)) ram = (last - first) / 2 + 1;
    }
    info->payload_size = (size_t)size;
    info->reset_pc = pc;
    info->sram = sram;
    info->ram_size = ram;
    return ROM_CART_OK;
}

// Recognition is intentionally conservative, not an emulator's game-specific heuristics.
// Position/mapping agreement and a valid checksum/complement pair distinguish headers
// from arbitrary code at the other location. Checksum itself is NOT recomputed here.
static bool snes_header(const uint8_t *h, size_t n, bool hi)
{
    if (!h || n < 64) return false;
    uint8_t mode = h[0x15];
    if ((hi && mode != 0x21 && mode != 0x31) ||
        (!hi && mode != 0x20 && mode != 0x30)) return false;
    uint16_t complement = h[0x1C] | (uint16_t)h[0x1D] << 8;
    uint16_t sum = h[0x1E] | (uint16_t)h[0x1F] << 8;
    uint16_t reset = h[0x3C] | (uint16_t)h[0x3D] << 8;
    return (uint16_t)(sum ^ complement) == UINT16_MAX && reset >= 0x8000;
}

rom_cart_result_t rom_parse_snes(const uint8_t *lo, size_t lo_n, const uint8_t *hi, size_t hi_n,
                                uint64_t size, rom_snes_info_t *info)
{
    if (!info) return ROM_CART_INVALID;
    memset(info, 0, sizeof *info);
    uint64_t prefix = size % 32768;
    if ((prefix != 0 && prefix != 512) || size < 32768 + prefix) return ROM_CART_INVALID;
    uint64_t payload = size - prefix;
    if (payload > 4 * 1024 * 1024) return ROM_CART_UNSUPPORTED;
    // Current snes_cart uses a size-1 mask. Reject non-power-of-two dumps until
    // a tested normalization/mirroring pass exists; never silently wrap 3 MiB.
    if (payload & (payload - 1)) return ROM_CART_UNSUPPORTED;
    bool low = snes_header(lo, lo_n, false);
    bool high = payload >= 65536 && snes_header(hi, hi_n, true);
    if (low && high) return ROM_CART_AMBIGUOUS;
    if (!low && !high) return ROM_CART_INVALID;
    const uint8_t *h = high ? hi : lo;
    uint8_t rom_exp = h[0x17], ram_exp = h[0x18];
    // 0=ROM, 1=ROM+RAM, 2=ROM+RAM+battery. Other types require missing cart hardware.
    if (h[0x16] > 2 || h[0x19] > 1 || rom_exp < 5 || rom_exp > 12 || ram_exp > 7)
        return ROM_CART_UNSUPPORTED;
    if (h[0x16] == 0 && ram_exp != 0) return ROM_CART_INVALID;
    // Bound the exponent before shifting; only the implemented cart layout is accepted.
    uint64_t declared = UINT64_C(1024) << rom_exp;
    if (payload > declared || payload <= declared / 2) return ROM_CART_INVALID;
    info->payload_offset = (size_t)prefix;
    info->payload_size = (size_t)payload;
    info->map = high ? ROM_SNES_HIROM : ROM_SNES_LOROM;
    info->fast_rom = (h[0x15] & 0x10) != 0;
    info->cart_type = h[0x16];
    info->region = h[0x19];
    info->ram_size = ram_exp ? 1024u << ram_exp : 0;
    memcpy(info->header, h, sizeof info->header);
    return ROM_CART_OK;
}
