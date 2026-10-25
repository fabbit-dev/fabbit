// Проверка настоящих загрузчиков с ошибками файлов, памяти и шины, без ESP и ПЛИС.
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fpga_link.h"
#include "nes_rom.h"
#include "profile_mgr.h"
#include "esp_vfs_fat.h"
#include "freertos/task.h"

enum { NORMAL, ALLOC_FAIL, READ_FAIL, NO_START, STREAM_FAIL, NO_SPACE, BAD_SPACE,
       NO_DONE, WRONG_CORE, TABLE_FAIL, FILE_GONE, SLOT_WRITE_FAIL, BOOT_FAIL,
       CACHE_CRC_FAIL };
static int mode, locks, resets, streamed, writes, boots, callbacks, opens;
static int64_t us;
static bool profile;
static pm_table_t table;

static void reset(int m)
{
    assert(locks == 0);
    mode = m;
    us = 0;
    resets = streamed = writes = boots = callbacks = opens = 0;
    profile = true;
    memset(&table, 0, sizeof table);
}

void fl_lock(void) { locks++; }
void fl_unlock(void) { assert(locks > 0); locks--; }
int64_t esp_timer_get_time(void) { us += 1000; return us; }
void vTaskDelay(TickType_t ticks) { us += (int64_t)ticks * 1000; }
void *heap_caps_malloc(size_t n, int caps) { return mode == ALLOC_FAIL ? NULL : malloc(n); }
esp_err_t esp_vfs_fat_spiflash_mount_ro(const char *a, const char *b, const esp_vfs_fat_mount_config_t *c)
{ return ESP_OK; }

FILE *test_fopen(const char *path, const char *flags)
{
    if (++opens == 2 && mode == FILE_GONE) return NULL;
    return fopen(!strncmp(path, "/data/", 6) ? path + 6 : path, flags);
}

uint32_t fl_crc32(uint32_t crc, const uint8_t *p, size_t n)
{
    crc = ~crc;
    while (n--) {
        crc ^= *p++;
        for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320u & -(crc & 1));
    }
    return ~crc;
}

esp_err_t fl_id(fl_id_t *id)
{
    assert(locks > 0);
    *id = (fl_id_t){.version = 3, .profile = 1};
    memcpy(id->magic, profile ? "FBPR" : "FBGL", 5);
    return ESP_OK;
}
esp_err_t fl_csr_read(uint8_t idx, uint32_t *v, size_t n)
{
    assert(locks > 0 && n == 1);
    if (mode == READ_FAIL) return ESP_ERR_INVALID_RESPONSE;
    switch (idx) {
    case NES_ID: *v = mode == WRONG_CORE ? 0 : NES_MAGIC; break;
    case NES_STAT:
        *v = !resets || mode == NO_START ? 2 :
             streamed >= 16400 && mode != NO_DONE ? 2 : 1;
        break;
    case NES_FREE: *v = mode == NO_SPACE ? 0 : mode == BAD_SPACE ? UINT32_MAX : 4096; break;
    case NES_RX: *v = streamed; break;
    default: *v = 0;
    }
    return ESP_OK;
}
esp_err_t fl_csr_write(uint8_t idx, const uint32_t *v, size_t n)
{
    assert(locks > 0 && idx == NES_CTRL && n == 1);
    resets++;
    return ESP_OK;
}
esp_err_t fl_write(uint8_t cmd, uint32_t addr, const void *p, size_t n)
{
    assert(locks > 0 && cmd == FL_CMD_STREAM);
    if (mode == STREAM_FAIL) return ESP_ERR_INVALID_RESPONSE;
    streamed += (int)n;
    return ESP_OK;
}
esp_err_t fl_wait_idle(uint32_t ms) { return ESP_OK; }
esp_err_t fl_tune(uint8_t start, bool fall) { return ESP_OK; }
esp_err_t fl_set_wdt(uint32_t n) { return ESP_OK; }
esp_err_t fl_boot(uint32_t addr)
{
    assert(locks > 0 && addr >= PM_SLOT_BASE);
    boots++;
    if (mode == BOOT_FAIL) return ESP_FAIL;
    profile = true;
    return ESP_OK;
}
esp_err_t fl_status(fl_status_t *st)
{
    memset(st, 0, sizeof *st);
    st->err_code = 5;  // прошлая команда: не должна мешать новому запуску
    return ESP_OK;
}
void fl_bootsts_str(uint32_t v, char *s, size_t n) { if (n) *s = 0; }
esp_err_t fl_flash_read(uint32_t addr, void *p, size_t n)
{
    assert(locks > 0 && addr == PM_TABLE_ADDR && n == sizeof table);
    if (mode == TABLE_FAIL) return ESP_ERR_TIMEOUT;
    memcpy(p, &table, n);
    return ESP_OK;
}
esp_err_t fl_flash_erase64k(uint32_t addr) { assert(locks > 0); return ESP_OK; }
esp_err_t fl_flash_program(uint32_t addr, const void *p, size_t n)
{
    assert(locks > 0 && addr == PM_TABLE_ADDR && n == sizeof table);
    memcpy(&table, p, n);
    return ESP_OK;
}
static const uint8_t image[] = {0xAA, 0x99, 0x55, 0x66};
esp_err_t fl_flash_crc(uint32_t addr, uint32_t n, uint32_t *crc)
{
    assert(locks > 0 && n == sizeof image);
    if (mode == CACHE_CRC_FAIL) return ESP_ERR_TIMEOUT;
    *crc = fl_crc32(0, image, n);
    return ESP_OK;
}
esp_err_t fl_flash_write_image(uint32_t addr, const uint8_t *p, size_t n,
                               void (*cb)(size_t, size_t))
{
    assert(locks > 0 && n == sizeof image && !memcmp(p, image, n));
    writes++;
    if (mode == SLOT_WRITE_FAIL) return ESP_FAIL;
    if (cb) cb(n, n);
    return ESP_OK;
}
static void progress(void *ctx, const char *stage, int pct) { assert(locks > 0); callbacks++; }

static void make_fbp(size_t len, bool corrupt)
{
    pm_header_t h = {.id = 1, .version = 1, .len = len};
    memcpy(h.magic, "FBP1", 4);
    h.crc = fl_crc32(0, image, sizeof image);
    h.hdr_crc = fl_crc32(0, (const uint8_t *)&h, 60);
    FILE *f = fopen("nes.fbp", "wb");
    assert(f);
    assert(fwrite(&h, 1, sizeof h, f) == sizeof h);
    if (len) assert(fwrite(image, 1, corrupt ? 2 : sizeof image, f) == (corrupt ? 2 : sizeof image));
    fclose(f);
}

int main(void)
{
    uint8_t h[16] = {'N', 'E', 'S', 0x1A, 1};
    nes_info_t info;
    assert(nes_parse(h, &info) && info.need == 16400);
    h[6] = 4;
    assert(!nes_parse(h, &info));
    h[6] = 0; h[7] = 8; h[9] = 1;
    assert(!nes_parse(h, &info));
    h[9] = 0;
    assert(nes_parse(h, &info));
    h[7] = 0; h[4] = 0;
    assert(!nes_parse(h, &info));
    h[4] = 1;
    FILE *f = fopen("test.nes", "wb");
    assert(f);
    assert(fwrite(h, 1, sizeof h, f) == sizeof h);
    for (int i = 0; i < 16384; i++) fputc(i & 255, f);
    fclose(f);
    const int cases[] = {NORMAL, ALLOC_FAIL, READ_FAIL, NO_START, STREAM_FAIL, NO_SPACE,
                         BAD_SPACE, NO_DONE, WRONG_CORE};
    const int expect[] = {ESP_OK, ESP_ERR_NO_MEM, ESP_ERR_INVALID_RESPONSE, ESP_ERR_TIMEOUT,
                          ESP_ERR_INVALID_RESPONSE, ESP_ERR_TIMEOUT, ESP_ERR_INVALID_RESPONSE,
                          ESP_ERR_TIMEOUT, ESP_ERR_INVALID_STATE};
    for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
        reset(cases[i]);
        esp_err_t e = nes_load_file("test.nes", NULL, NULL, NULL);
        assert(e == expect[i] && locks == 0);
        if (cases[i] == NO_START || cases[i] == WRONG_CORE) assert(!streamed);
    }
    puts("ok NES: parser, no memory, bus errors, start/stream/done timeouts, wrong core");

    const int pm_cases[] = {NORMAL, ALLOC_FAIL, TABLE_FAIL, FILE_GONE, SLOT_WRITE_FAIL, BOOT_FAIL};
    const int pm_expect[] = {ESP_OK, ESP_ERR_NO_MEM, ESP_ERR_TIMEOUT, ESP_ERR_NOT_FOUND, ESP_FAIL, ESP_FAIL};
    for (size_t i = 0; i < sizeof pm_cases / sizeof *pm_cases; i++) {
        reset(pm_cases[i]);
        profile = false;
        make_fbp(sizeof image, false);
        esp_err_t e = pm_load_cb("nes", false, progress, NULL);
        assert(e == pm_expect[i] && locks == 0);
        if (e == ESP_OK) assert(writes == 1 && boots == 1 && callbacks > 0);
        else if (mode != BOOT_FAIL) assert(!boots);
        if (mode == TABLE_FAIL) assert(!writes);
    }
    reset(NORMAL);
    profile = false;
    make_fbp(0, false);
    assert(pm_load("nes", false) == ESP_ERR_INVALID_CRC && !writes && !locks);
    make_fbp(sizeof image, true);
    assert(pm_load("nes", false) == ESP_ERR_INVALID_CRC && !writes && !locks);
    make_fbp(sizeof image, false);
    profile = true;
    assert(pm_load("nes", false) == ESP_ERR_INVALID_STATE && !writes && !locks);
    reset(NORMAL);
    profile = false;
    assert(pm_load_cb("nes", false, progress, NULL) == ESP_OK);
    int cb_before = callbacks;
    profile = false;
    writes = 0;
    assert(pm_load("nes", false) == ESP_OK && !writes && callbacks == cb_before && !locks);
    profile = false;
    mode = CACHE_CRC_FAIL;
    assert(pm_load("nes", false) == ESP_ERR_TIMEOUT && !writes && !locks);
    mode = NORMAL;
    // Насыщение used не оставляет slot == -1 при заполненном кэше.
    profile = false;
    for (int i = 0; i < PM_SLOTS; i++) table.slot[i] = (pm_slot_t){.crc = 1, .used = UINT32_MAX};
    table.crc = fl_crc32(0, (const uint8_t *)&table, offsetof(pm_table_t, crc));
    assert(pm_load("nes", false) == ESP_OK && writes == 1 && !locks);
    puts("ok profiles: no memory, table read failure, removed/truncated/empty file, write/boot failure");
    puts("ALL OK");
    return 0;
}
