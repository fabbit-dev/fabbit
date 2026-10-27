// Профили: файлы .fbp (host/tools/fbp_pack.py), слоты во флеше ПЛИС, кэш по CRC, загрузка через golden.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#define PM_SLOTS 5
#define PM_SLOT_BASE 0x400000u
#define PM_SLOT_SIZE 0x240000u
#define PM_TABLE_ADDR 0xFF0000u  // сектор таблицы слотов
// watchdog конфигурации для BOOT (x64 отсчётов): пустой слот откатывается на адрес 0 (время не мерено),
// рабочий профиль (0,56 с при CCLK 33 МГц) не задевает. Подобрано на макете 2026-10-15
#define PM_WDT_UNITS 0x1000u

typedef struct {
    char magic[4];  // "FBP1"
    uint16_t id;
    uint8_t flags, version;
    uint32_t len, crc;
    char name[32];
    uint32_t cor0;
    uint8_t reserved[8];
    uint32_t hdr_crc;
} __attribute__((packed)) pm_header_t;

typedef struct {
    uint32_t crc, len;  // 0: слот пуст
    uint16_t id, pad;
    uint32_t used;  // счётчик загрузок для LRU
} __attribute__((packed)) pm_slot_t;

typedef struct {
    char magic[4];  // "FBST"
    uint32_t version, seq;
    pm_slot_t slot[PM_SLOTS];
    uint32_t crc;  // CRC32 всего, что выше
} __attribute__((packed)) pm_table_t;

// смонтировать хранилище профилей (раздел storage, FAT, только чтение) в /data
esp_err_t pm_init(void);
// есть ли в хранилище профиль с этим именем и целым заголовком; ПЛИС не трогает
bool pm_available(const char *file);
// напечатать профили (*.fbp) с заголовками
void pm_list(void);
// напечатать таблицу слотов из флеша ПЛИС
esp_err_t pm_slots(void);
// этап загрузки для экрана: stage — что идёт, pct — доля 0..100 или −1
typedef void (*pm_progress_cb)(void *ctx, const char *stage, int pct);
// загрузить профиль: файл в PSRAM, слот (из кэша или запись), BOOT, ожидание ID профиля.
// cb может быть NULL; зовётся из той же задачи
esp_err_t pm_load(const char *file, bool force_write);
esp_err_t pm_load_cb(const char *file, bool force_write, pm_progress_cb cb, void *ctx);
