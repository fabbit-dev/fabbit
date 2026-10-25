#include "rom_file.h"
#include "rom_cart.h"
#include <string.h>
#include <strings.h>

static const char *extension(const char *path)
{
    const char *slash = path ? strrchr(path, '/') : NULL;
    const char *dot = path ? strrchr(path, '.') : NULL;
    return dot && (!slash || dot > slash) ? dot : "";
}

bool rom_candidate(const char *path)
{
    const char *ext = extension(path);
    return !strcasecmp(ext, ".nes") || !strcasecmp(ext, ".md") ||
           !strcasecmp(ext, ".gen") || !strcasecmp(ext, ".bin") ||
           !strcasecmp(ext, ".sfc") || !strcasecmp(ext, ".smc");
}

bool rom_sidecar(const char *path, const char *suffix, char *out, size_t capacity)
{
    if (!path || !suffix || !out || !capacity) return false;
    const char *ext = extension(path);
    size_t base = *ext ? (size_t)(ext - path) : strlen(path);
    if (base + strlen(suffix) + 1 > capacity) return false;
    memcpy(out, path, base);
    strcpy(out + base, suffix);
    return true;
}

static rom_result_t cart_result(rom_cart_result_t r)
{
    return r == ROM_CART_OK ? ROM_OK : r == ROM_CART_UNSUPPORTED ? ROM_UNAVAILABLE : ROM_INVALID;
}

rom_result_t rom_probe_file(FILE *f, const char *path, rom_info_t *info)
{
    if (!info) return ROM_INVALID;
    memset(info, 0, sizeof *info);
    if (!f || fseek(f, 0, SEEK_END)) return ROM_INVALID;
    long size = ftell(f);
    if (size < 0 || fseek(f, 0, SEEK_SET)) return ROM_INVALID;
    uint8_t h[512];
    size_t n = fread(h, 1, sizeof h, f);
    if (ferror(f)) return ROM_INVALID;
    rom_info_t result = {0};
    rom_result_t r = rom_probe(h, n, (uint64_t)size, path, &result);
    if (result.system == ROM_NES) {
        if (r == ROM_OK) {
            result.rom_size = (uint32_t)(result.payload_size - 16);
            *info = result;
        }
        return r;
    }
    const char *ext = extension(path);
    if (!strcasecmp(ext, ".md") || !strcasecmp(ext, ".gen") ||
        !strcasecmp(ext, ".bin")) {
        rom_md_info_t md;
        r = cart_result(rom_parse_md(h, n, (uint64_t)size, &md));
        if (r != ROM_OK) return r;
        result = (rom_info_t){.system = ROM_MD, .payload_size = md.payload_size,
                              .rom_size = (uint32_t)md.payload_size, .save_size = md.ram_size};
    } else if (!strcasecmp(ext, ".sfc") || !strcasecmp(ext, ".smc")) {
        uint8_t lo[64], hi[64];
        size_t ln = 0, hn = 0;
        long prefix = size % 32768;
        if (prefix != 0 && prefix != 512) return ROM_INVALID;
        if (size >= prefix + 32768) {
            if (fseek(f, prefix + 0x7fc0, SEEK_SET)) return ROM_INVALID;
            ln = fread(lo, 1, sizeof lo, f);
            if (ln != sizeof lo) return ROM_INVALID;
        }
        if (size >= prefix + 65536) {
            if (fseek(f, prefix + 0xffc0, SEEK_SET)) return ROM_INVALID;
            hn = fread(hi, 1, sizeof hi, f);
            if (hn != sizeof hi) return ROM_INVALID;
        }
        if (ferror(f)) return ROM_INVALID;
        rom_snes_info_t snes;
        r = cart_result(rom_parse_snes(lo, ln, hi, hn, (uint64_t)size, &snes));
        if (r != ROM_OK) return r;
        result = (rom_info_t){.system = ROM_SNES, .payload_offset = snes.payload_offset,
                              .payload_size = snes.payload_size, .rom_size = (uint32_t)snes.payload_size,
                              .save_size = snes.ram_size, .map = snes.map, .fast_rom = snes.fast_rom};
    } else return ROM_UNKNOWN;
    *info = result;
    return ROM_OK;
}
