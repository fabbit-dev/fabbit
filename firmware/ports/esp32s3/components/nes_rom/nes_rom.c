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
    if (memcmp(h, "NES\x1a", 4)) return false;
    info->mapper = (h[6] >> 4) | (h[7] & 0xF0);
    info->prg_kb = h[4] * 16;
    info->chr_kb = h[5] * 8;
    info->need = 16 + h[4] * 16384u + h[5] * 8192u;
    return h[4] <= 32 && h[5] <= 32;
}

bool nes_present(void)
{
    fl_id_t id;
    return fl_id(&id) == ESP_OK && !strcmp(id.magic, "FBPR") && fl_csr_get(NES_ID) == NES_MAGIC;
}

esp_err_t nes_load_file(const char *path, void (*progress)(void *ctx, int pct), void *ctx,
                        uint32_t *ms)
{
    FILE *f = fopen(path, "rb");
    if (!f) return ESP_ERR_NOT_FOUND;
    uint8_t *rom = heap_caps_malloc(NES_ROM_MAX + 8192, MALLOC_CAP_SPIRAM);
    size_t n = rom ? fread(rom, 1, NES_ROM_MAX + 8192, f) : 0;
    fclose(f);
    nes_info_t info;
    if (!rom || n < 16 || !nes_parse(rom, &info) || info.need > n) {
        free(rom);
        ESP_LOGE(TAG, "%s: не iNES, обрезан или не влезает (PRG до 512 КБ, CHR до 256 КБ)", path);
        return ESP_ERR_INVALID_SIZE;
    }
    int64_t t0 = esp_timer_get_time();
    fl_csr_set(NES_CTRL, NES_KEY | 1);
    int64_t end = esp_timer_get_time() + 1000000;
    while (!(fl_csr_get(NES_STAT) & 1) && esp_timer_get_time() < end) vTaskDelay(1);
    size_t sent = 0;
    int last = -1;
    end = esp_timer_get_time() + 5000000;
    while (sent < info.need && esp_timer_get_time() < end) {
        uint32_t free_b = fl_csr_get(NES_FREE);
        size_t k = info.need - sent;
        if (k > free_b) k = free_b;
        if (k > FL_BUF_SIZE) k = FL_BUF_SIZE;
        if (k < 256 && k < info.need - sent) {
            vTaskDelay(1);
            continue;
        }
        if (fl_write(FL_CMD_STREAM, 0, rom + sent, k) != ESP_OK) break;
        sent += k;
        int pct = (int)(sent * 100 / info.need);
        if (progress && pct / 10 != last / 10) progress(ctx, pct), last = pct;
    }
    free(rom);
    end = esp_timer_get_time() + 3000000;
    uint32_t st;
    while (((st = fl_csr_get(NES_STAT)) & 1) && esp_timer_get_time() < end) vTaskDelay(1);
    int64_t us = esp_timer_get_time() - t0;
    if (ms) *ms = (uint32_t)(us / 1000);
    ESP_LOGI(TAG, "ROM %u Б за %lld мс (%.2f МБ/с), принято ПЛИС %" PRIu32 ": %s", (unsigned)sent,
             us / 1000, sent / (double)us, fl_csr_get(NES_RX),
             (st & 4) ? "ошибка загрузчика" : (st & 2) ? "запущен" : "не завершён");
    return (st & 6) == 2 ? ESP_OK : ESP_FAIL;
}
