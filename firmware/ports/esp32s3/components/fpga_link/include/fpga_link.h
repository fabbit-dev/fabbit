// Шина ESP32-S3 -> ПЛИС (quad SPI, half-duplex) и команды golden-образа.
// Протокол: docs/bus-protocol.md
#pragma once
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#define FL_BUF_SIZE 8192
#define FL_PROT_TOP 0x400000u  // ниже golden: стирание и запись запрещены

typedef enum {
    FL_CMD_ID = 0x01,
    FL_CMD_STATUS = 0x02,
    FL_CMD_BUF_W = 0x03,
    FL_CMD_BUF_R = 0x04,
    FL_CMD_PARAM = 0x05,
    FL_CMD_RESULT = 0x06,
    FL_CMD_TUNE = 0x07,  // addr[7:0] rd_start, addr[8] выдача по заднему фронту
    FL_CMD_ERASE = 0x10,
    FL_CMD_PROG = 0x11,
    FL_CMD_READ = 0x12,
    FL_CMD_CRC = 0x13,
    FL_CMD_FL_ID = 0x14,
    FL_CMD_FL_SR = 0x15,
    FL_CMD_FL_WRSR = 0x16,  // addr[7:0] SR (только BP), addr[15:8] CR
    FL_CMD_BOOT = 0x20,
    FL_CMD_SET_WDT = 0x21,  // addr: TIMER для BOOT в единицах 64 отсчётов, 0 = нет
    FL_CMD_REBOOT_GOLDEN = 0x22,  // оболочка профиля, с ключом (ICAP: только сборка Vivado)
    FL_CMD_CSR_W = 0x30,          // оболочка профиля: addr = индекс регистра, слова BE
    FL_CMD_CSR_R = 0x31,
    FL_CMD_STREAM = 0x32,         // оболочка профиля: addr = канал, байты потока
    FL_CMD_PAD = 0x33,            // оболочка профиля: 4 байта {пад 1, пад 0}, BE
} fl_cmd_t;

typedef struct {
    char magic[5];     // "FBGL" golden, "FBPR" профиль
    uint8_t version;
    uint8_t mode;      // 0 golden, 1 профиль
    uint16_t profile;  // id профиля
} fl_id_t;

typedef struct {
    uint8_t busy, error;
    uint8_t err_code;
    uint32_t bootsts;
} fl_status_t;

esp_err_t fl_init(uint32_t hz);
// замок шины (рекурсивный): каждый кадр берёт его сам; держать вокруг серии кадров, которую
// нельзя разрывать чужими (например, «записать CSR и прочитать ответ»)
void fl_lock(void);
void fl_unlock(void);
esp_err_t fl_set_freq(uint32_t hz);
uint32_t fl_get_freq(void);
// прозвонка: линии SCK, CS, IO0..3, IRQ по очереди в 1 на 300 мс
esp_err_t fl_wiretest(void);
// момент выдачи данных ПЛИС: передних фронтов SCK до первого нибла, по заднему фронту
esp_err_t fl_tune(uint8_t rd_start, bool rd_fall);
// уровни 7 линий (биты как в wiretest) со своей подтяжкой вниз и вверх
esp_err_t fl_pins(uint8_t *with_pd, uint8_t *with_pu);

esp_err_t fl_write(uint8_t cmd, uint32_t addr, const void *data, size_t len);
esp_err_t fl_read(uint8_t cmd, uint32_t addr, void *data, size_t len);

esp_err_t fl_id(fl_id_t *id);
esp_err_t fl_status(fl_status_t *st);
// ждать IRQ (golden свободен), затем проверить ошибку
esp_err_t fl_wait_idle(uint32_t timeout_ms);

esp_err_t fl_buf_write(uint32_t off, const void *data, size_t len);
esp_err_t fl_buf_read(uint32_t off, void *data, size_t len);
esp_err_t fl_param(uint32_t len, uint32_t buf_off);
esp_err_t fl_result(uint32_t *v);

esp_err_t fl_flash_id(uint32_t *jedec);
esp_err_t fl_flash_erase64k(uint32_t addr);
// регистры статуса и конфигурации флеша; запись меняет только BP (защита снизу при TB=1)
esp_err_t fl_flash_sr(uint8_t *sr, uint8_t *cr);
esp_err_t fl_flash_wrsr(uint8_t sr, uint8_t cr);
// записать len байт (<= FL_BUF_SIZE) из data по адресу addr через буфер ПЛИС
esp_err_t fl_flash_program(uint32_t addr, const void *data, size_t len);
// записать образ целиком: стирание по 64К, двойная буферизация, прогресс в cb
esp_err_t fl_flash_write_image(uint32_t addr, const uint8_t *data, size_t len,
                               void (*progress)(size_t done, size_t total));
esp_err_t fl_flash_read(uint32_t addr, void *data, size_t len);
esp_err_t fl_flash_crc(uint32_t addr, uint32_t len, uint32_t *crc);
esp_err_t fl_boot(uint32_t addr);
// watchdog конфигурации для следующего BOOT: units*64 отсчётов, 0 = выключен
esp_err_t fl_set_wdt(uint32_t units);
esp_err_t fl_reboot_golden(void);

uint32_t fl_crc32(uint32_t crc, const uint8_t *p, size_t n);
// регистры профиля: n слов с индекса idx (не больше 64)
esp_err_t fl_csr_write(uint8_t idx, const uint32_t *v, size_t n);
esp_err_t fl_csr_read(uint8_t idx, uint32_t *v, size_t n);
static inline esp_err_t fl_csr_set(uint8_t idx, uint32_t v) { return fl_csr_write(idx, &v, 1); }
static inline uint32_t fl_csr_get(uint8_t idx)
{
    uint32_t v = 0;
    fl_csr_read(idx, &v, 1);
    return v;
}
// кнопки в профиль: pad0 = джойстик 1, pad1 = джойстик 2 (биты PAD_*, docs/bus-protocol.md)
esp_err_t fl_pad(uint16_t pad0, uint16_t pad1);
// BOOTSTS (UG470) по-человечески: "сейчас: ...; до этого: ..."
void fl_bootsts_str(uint32_t v, char *out, size_t n);
