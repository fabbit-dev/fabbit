// Профиль NES (gateware/profiles/nes/nes_top.sv): разбор iNES и загрузка ROM потоком 0.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

enum { NES_ID = 0, NES_CTRL = 1, NES_STAT = 2, NES_FREE = 3, NES_RX = 4, NES_JOY = 5 };
#define NES_MAGIC 0x464E4553u  // "FNES" в CSR 0
#define NES_KEY 0x4E530000u    // "NS" в старших 16 битах: без него управление игнорируется
#define NES_ROM_MAX (16 + 512 * 1024 + 256 * 1024)  // PRG ≤ 512 КБ, CHR ≤ 256 КБ (nes_sdram.sv)

typedef struct {
    uint8_t mapper;
    uint16_t prg_kb, chr_kb;
    size_t need;  // заголовок + PRG + CHR
} nes_info_t;

// Заголовок 16 байт; false: не iNES, trainer, расширенные размеры NES 2.0 или не влезает в SDRAM.
bool nes_parse(const uint8_t h[16], nes_info_t *info);
// в ПЛИС профиль NES
bool nes_present(void);
// файл целиком в ПЛИС: сброс загрузчика, поток с учётом места в FIFO, ожидание запуска.
// progress: 0..100 по ходу передачи, может быть NULL
esp_err_t nes_load_file(const char *path, void (*progress)(void *ctx, int pct), void *ctx,
                        uint32_t *ms);
