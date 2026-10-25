#include "rom.h"

#include <string.h>

bool rom_parse_nes(const uint8_t *h, size_t n, rom_nes_info_t *info)
{
    if (!info) return false;
    memset(info, 0, sizeof *info);
    if (!h || n < 16 || memcmp(h, "NES\x1a", 4) || !h[4] || h[4] > 32 || h[5] > 32 ||
        (h[6] & 4) || ((h[7] & 0x0C) != 0 && (h[7] & 0x0C) != 8) ||
        ((h[7] & 0x0C) == 8 && h[9])) return false;
    info->mapper = (h[6] >> 4) | (h[7] & 0xF0);
    if ((h[7] & 0x0C) != 8) {
        bool dirty = (h[9] & 0xFE) != 0;
        for (int i = 10; i < 16; i++) dirty |= h[i] != 0;
        if (dirty) info->mapper = h[6] >> 4;  // как GameLoader
    }
    info->prg_kb = h[4] * 16;
    info->chr_kb = h[5] * 8;
    info->need = 16 + h[4] * 16384u + h[5] * 8192u;
    return true;
}

static bool suffix(const char *path, const char *ext)
{
    if (!path) return false;
    const char *dot = strrchr(path, '.');
    if (!dot) return false;
    while (*dot && *ext) {
        unsigned char c = (unsigned char)*dot++;
        if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
        if (c != (unsigned char)*ext++) return false;
    }
    return !*dot && !*ext;
}

rom_result_t rom_probe(const uint8_t *h, size_t n, uint64_t file_size,
                       const char *path, rom_info_t *info)
{
    if (!info) return ROM_INVALID;
    memset(info, 0, sizeof *info);
    if ((!h && n) || n > file_size) return ROM_INVALID;
    if ((n >= 4 && !memcmp(h, "NES\x1a", 4)) || suffix(path, ".nes")) {
        info->system = ROM_NES;
        rom_nes_info_t nes;
        if (!rom_parse_nes(h, n, &nes) || nes.need > file_size) return ROM_INVALID;
        info->nes = nes;
        info->payload_size = nes.need;
        return ROM_OK;
    }
    if (suffix(path, ".md") || suffix(path, ".gen")) info->system = ROM_MD;
    else if (suffix(path, ".sfc") || suffix(path, ".smc")) info->system = ROM_SNES;
    return info->system == ROM_NONE ? ROM_UNKNOWN : ROM_UNAVAILABLE;
}
