// Распознавание ROM без файловой системы и оборудования. Hint не означает поддержку ядром.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum { ROM_NONE, ROM_NES, ROM_MD, ROM_SNES } rom_system_t;
typedef enum { ROM_OK, ROM_INVALID, ROM_UNKNOWN, ROM_UNAVAILABLE } rom_result_t;

typedef struct {
    uint8_t mapper;
    uint16_t prg_kb, chr_kb;
    size_t need;  // iNES header + PRG + CHR; legacy NES wire format
} rom_nes_info_t;

typedef struct {
    rom_system_t system;
    size_t payload_offset, payload_size;  // заданы только при ROM_OK
    rom_nes_info_t nes;
} rom_info_t;

// Policy существующего NES GameLoader: trainer/расширенные размеры не поддерживаются.
bool rom_parse_nes(const uint8_t *header, size_t header_size, rom_nes_info_t *info);
// Нужны первые 16 байт и полный размер файла. Валидный iNES имеет приоритет над suffix.
// MD/SNES пока только подсказки по suffix с ROM_UNAVAILABLE, без validation/payload.
// .bin неоднозначен. При ошибке payload/metadata очищаются, system может содержать hint.
rom_result_t rom_probe(const uint8_t *header, size_t header_size, uint64_t file_size,
                       const char *path, rom_info_t *info);
