// Файловая граница ROM: общий preflight для каталога, запуска меню и консоли.
#pragma once
#include "esp_err.h"
#include "rom.h"

// Только чтение файла; не проверяет/не меняет состояние ПЛИС.
esp_err_t rom_port_probe(const char *path, rom_info_t *info);
// Preflight, затем один из реализованных загрузчиков. Сейчас только NES.
esp_err_t rom_port_load(const char *path, void (*progress)(void *ctx, int pct), void *ctx,
                         uint32_t *ms);
