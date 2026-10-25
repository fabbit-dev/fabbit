#include "nes_rom.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "fpga_link.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "nes";

bool nes_parse(const uint8_t h[16], nes_info_t *info)
{
    // GameLoader не поддерживает trainer и расширенные размеры NES 2.0.
    if (memcmp(h, "NES\x1a", 4) || !h[4] || h[4] > 32 || h[5] > 32 || (h[6] & 4) ||
        ((h[7] & 0x0C) != 0 && (h[7] & 0x0C) != 8) ||
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

bool nes_present(void)
{
    fl_id_t id;
    return fl_id(&id) == ESP_OK && !strcmp(id.magic, "FBPR") && fl_csr_get(NES_ID) == NES_MAGIC;
}

static esp_err_t load_file_locked(const char *path, void (*progress)(void *ctx, int pct), void *ctx,
                                  uint32_t *ms)
{
    if (ms) *ms = 0;
    FILE *f = fopen(path, "rb");
    if (!f) return ESP_ERR_NOT_FOUND;
    uint8_t *rom = heap_caps_malloc(NES_ROM_MAX + 8192, MALLOC_CAP_SPIRAM);
    size_t n = rom ? fread(rom, 1, NES_ROM_MAX + 8192, f) : 0;
    fclose(f);
    if (!rom) return ESP_ERR_NO_MEM;
    nes_info_t info;
    if (n < 16 || !nes_parse(rom, &info) || info.need > n) {
        free(rom);
        ESP_LOGE(TAG, "%s: не iNES, обрезан или не влезает (PRG до 512 КБ, CHR до 256 КБ)", path);
        return ESP_ERR_INVALID_SIZE;
    }
    fl_id_t id;
    uint32_t magic;
    esp_err_t e = fl_id(&id);
    if (e == ESP_OK && strcmp(id.magic, "FBPR")) e = ESP_ERR_INVALID_STATE;
    if (e == ESP_OK) e = fl_csr_read(NES_ID, &magic, 1);
    if (e == ESP_OK && magic != NES_MAGIC) e = ESP_ERR_INVALID_STATE;
    if (e != ESP_OK) { free(rom); return e; }
    int64_t t0 = esp_timer_get_time();
    e = fl_csr_set(NES_CTRL, NES_KEY | 1);
    int64_t end = esp_timer_get_time() + 1000000;
    uint32_t st = 0;
    while (e == ESP_OK && esp_timer_get_time() < end) {
        e = fl_csr_read(NES_STAT, &st, 1);
        if (e != ESP_OK || (st & 1)) break;
        vTaskDelay(1);
    }
    if (e == ESP_OK && !(st & 1)) e = ESP_ERR_TIMEOUT;
    size_t sent = 0;
    int last = -1;
    end = esp_timer_get_time() + 5000000;
    while (e == ESP_OK && sent < info.need && esp_timer_get_time() < end) {
        uint32_t free_b;
        e = fl_csr_read(NES_FREE, &free_b, 1);
        if (e != ESP_OK) break;
        if (free_b > 4096) { e = ESP_ERR_INVALID_RESPONSE; break; }
        size_t k = info.need - sent;
        if (k > free_b) k = free_b;
        if (k > FL_BUF_SIZE) k = FL_BUF_SIZE;
        if (k < 256 && k < info.need - sent) {
            vTaskDelay(1);
            continue;
        }
        e = fl_write(FL_CMD_STREAM, 0, rom + sent, k);
        if (e != ESP_OK) break;
        sent += k;
        int pct = (int)(sent * 100 / info.need);
        if (progress && pct / 10 != last / 10) progress(ctx, pct), last = pct;
    }
    free(rom);
    if (e != ESP_OK) return e;
    if (sent != info.need) return ESP_ERR_TIMEOUT;
    end = esp_timer_get_time() + 3000000;
    do {
        e = fl_csr_read(NES_STAT, &st, 1);
        if (e != ESP_OK) return e;
        if (!(st & 1)) break;
        vTaskDelay(1);
    } while (esp_timer_get_time() < end);
    int64_t us = esp_timer_get_time() - t0;
    if (ms) *ms = (uint32_t)(us / 1000);
    ESP_LOGI(TAG, "ROM %u Б за %" PRId64 " мс (%.2f МБ/с), принято ПЛИС %" PRIu32 ": %s", (unsigned)sent,
             us / 1000, sent / (double)us, fl_csr_get(NES_RX),
             (st & 4) ? "ошибка загрузчика" : (st & 2) ? "запущен" : "не завершён");
    if (st & 1) return ESP_ERR_TIMEOUT;
    return (st & 6) == 2 ? ESP_OK : ESP_FAIL;
}

esp_err_t nes_load_file(const char *path, void (*progress)(void *ctx, int pct), void *ctx,
                        uint32_t *ms)
{
    fl_lock();
    esp_err_t e = load_file_locked(path, progress, ctx, ms);
    fl_unlock();
    return e;
}
