#include "rom_port.h"

#include <stdio.h>
#include <string.h>

#include "nes_rom.h"
#include "retro_rom.h"
#include "rom_file.h"
#include "fpga_link.h"

esp_err_t rom_port_probe(const char *path, rom_info_t *info)
{
    if (!info) return ESP_ERR_INVALID_ARG;
    memset(info, 0, sizeof *info);
    if (!path) return ESP_ERR_INVALID_ARG;
    FILE *f = fopen(path, "rb");
    if (!f) return ESP_ERR_NOT_FOUND;
    rom_result_t result = rom_probe_file(f, path, info);
    int close_err = fclose(f);
    if (close_err) return ESP_FAIL;
    switch (result) {
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
    // Serialize profile detection and transfer; no race with console/menu BOOT.
    fl_lock();
    if (retro_present()) e = retro_load_file(path, progress, ctx, ms);
    else if (info.system == ROM_NES) e = nes_load_file(path, progress, ctx, ms);
    else e = ESP_ERR_NOT_SUPPORTED;
    fl_unlock();
    return e;
}
