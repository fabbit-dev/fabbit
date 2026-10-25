#include "rom_port.h"

#include <stdio.h>
#include <string.h>

#include "nes_rom.h"

esp_err_t rom_port_probe(const char *path, rom_info_t *info)
{
    if (!info) return ESP_ERR_INVALID_ARG;
    memset(info, 0, sizeof *info);
    if (!path) return ESP_ERR_INVALID_ARG;
    FILE *f = fopen(path, "rb");
    if (!f) return ESP_ERR_NOT_FOUND;
    uint8_t h[16];
    size_t n = fread(h, 1, sizeof h, f);
    bool read_ok = !ferror(f);
    long size = -1;
    if (read_ok && !fseek(f, 0, SEEK_END)) size = ftell(f);
    int close_err = fclose(f);
    if (!read_ok || size < 0 || close_err) return ESP_FAIL;
    switch (rom_probe(h, n, (uint64_t)size, path, info)) {
    case ROM_OK: return ESP_OK;
    case ROM_INVALID: return ESP_ERR_INVALID_SIZE;
    default: return ESP_ERR_NOT_SUPPORTED;
    }
}

esp_err_t rom_port_load(const char *path, void (*progress)(void *ctx, int pct), void *ctx,
                         uint32_t *ms)
{
    if (ms) *ms = 0;
    rom_info_t info;
    esp_err_t e = rom_port_probe(path, &info);
    if (e != ESP_OK) return e;
    switch (info.system) {
    case ROM_NES: return nes_load_file(path, progress, ctx, ms);
    default: return ESP_ERR_NOT_SUPPORTED;
    }
}
