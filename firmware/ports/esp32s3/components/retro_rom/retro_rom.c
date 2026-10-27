#include "retro_rom.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rom_file.h"
#include "fpga_link.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define COMMAND_US 2000000LL
#define STREAM_US 30000000LL
#define CHUNK 4096u
#define FIFO_MARGIN 16u

typedef struct { uint8_t ipl[64], coeff[1024]; } assets_t;

static esp_err_t exact_file(const char *path, uint8_t *out, size_t n)
{
    FILE *f = fopen(path, "rb");
    if (!f) return ESP_ERR_NOT_FOUND;
    bool ok = fread(out, 1, n, f) == n;
    int extra = fgetc(f);
    bool io = ferror(f);
    int closed = fclose(f);
    if (io || closed) return ESP_FAIL;
    return ok && extra == EOF ? ESP_OK : ESP_ERR_INVALID_SIZE;
}

static esp_err_t read_assets(assets_t *a)
{
    esp_err_t e = exact_file(RETRO_SNES_IPL_PATH, a->ipl, sizeof a->ipl);
    if (e == ESP_OK) e = exact_file(RETRO_SNES_GAUSS_PATH, a->coeff, sizeof a->coeff);
    if (e != ESP_OK) return e;
    for (size_t i = 1; i < sizeof a->coeff; i += 2)
        if (a->coeff[i] & 0xf0) return ESP_ERR_INVALID_RESPONSE;
    // Fail closed for placeholder/erased assets, without assuming a proprietary hash.
    bool ipl_data = false, coeff_data = false;
    for (size_t i = 1; i < sizeof a->ipl; i++) ipl_data |= a->ipl[i] != a->ipl[0];
    for (size_t i = 0; i < sizeof a->coeff; i++) coeff_data |= a->coeff[i] != 0;
    return ipl_data && coeff_data ? ESP_OK : ESP_ERR_INVALID_RESPONSE;
}

static esp_err_t probe(FILE *f, const char *path, rom_info_t *info)
{
    rom_result_t r = rom_probe_file(f, path, info);
    return r == ROM_OK ? ESP_OK : r == ROM_INVALID ? ESP_ERR_INVALID_SIZE : ESP_ERR_NOT_SUPPORTED;
}

esp_err_t retro_preflight(const char *path, rom_info_t *info)
{
    if (!path || !info) return ESP_ERR_INVALID_ARG;
    memset(info, 0, sizeof *info);
    FILE *f = fopen(path, "rb");
    if (!f) return ESP_ERR_NOT_FOUND;
    esp_err_t e = probe(f, path, info);
    if (fclose(f) && e == ESP_OK) e = ESP_FAIL;
    if (e == ESP_OK && info->system == ROM_SNES) {
        assets_t a;
        e = read_assets(&a);
    }
    return e;
}

static esp_err_t check_profile(rom_system_t system)
{
    fl_id_t id;
    esp_err_t e = fl_id(&id);
    if (e != ESP_OK) return e;
    if (strcmp(id.magic, "FBPR") || id.profile != RETRO_PROFILE_ID) return ESP_ERR_INVALID_STATE;
    uint32_t magic, abi, caps;
    e = fl_csr_read(RETRO_ID, &magic, 1);
    if (e == ESP_OK) e = fl_csr_read(RETRO_ABI, &abi, 1);
    if (e == ESP_OK) e = fl_csr_read(RETRO_CAPS, &caps, 1);
    if (e != ESP_OK) return e;
    if (magic != RETRO_MAGIC || abi != 1) return ESP_ERR_INVALID_RESPONSE;
    if (system != ROM_NONE && !(caps & (1u << (system - 1)))) return ESP_ERR_NOT_SUPPORTED;
    return ESP_OK;
}

bool retro_present(void) { return check_profile(ROM_NONE) == ESP_OK; }
bool retro_supports(rom_system_t system)
{
    return system != ROM_NONE && check_profile(system) == ESP_OK;
}

static esp_err_t wait_status(uint32_t mask, uint32_t value, bool error, int64_t deadline)
{
    do {
        uint32_t st;
        esp_err_t e = fl_csr_read(RETRO_STAT, &st, 1);
        if (e != ESP_OK) return e;
        if (error && (st & RETRO_FAILED)) return ESP_FAIL;
        if ((st & mask) == value) return ESP_OK;
        vTaskDelay(1);
    } while (esp_timer_get_time() < deadline);
    return ESP_ERR_TIMEOUT;
}

// Every mailbox write has its own before/after handshake. fl_* serializes real
// bus transactions, supplying the 100 MHz command CDC visibility latency.
static esp_err_t mailbox(uint8_t index, uint32_t value, bool error)
{
    esp_err_t e = wait_status(RETRO_CMD_BUSY, 0, error, esp_timer_get_time() + COMMAND_US);
    if (e == ESP_OK) e = fl_csr_set(index, value);
    if (e == ESP_OK) e = wait_status(RETRO_CMD_BUSY, 0, error, esp_timer_get_time() + COMMAND_US);
    return e;
}

static esp_err_t abort_drain(void)
{
    esp_err_t e = mailbox(RETRO_CTRL, RETRO_KEY | RETRO_ABORT, false);
    if (e == ESP_OK)
        e = wait_status(RETRO_CMD_BUSY | RETRO_DRAIN_BUSY | RETRO_LOADING | RETRO_RUNNING,
                        0, false, esp_timer_get_time() + COMMAND_US);
    return e;
}

static esp_err_t program_assets(const assets_t *a)
{
    esp_err_t e = mailbox(RETRO_CTRL, RETRO_KEY | RETRO_CLEAR_IPL, true);
    for (uint32_t i = 0; e == ESP_OK && i < sizeof a->ipl; i++)
        e = mailbox(RETRO_IPL, i << 8 | a->ipl[i], true);
    if (e == ESP_OK) e = mailbox(RETRO_CTRL, RETRO_KEY | RETRO_CLEAR_COEFF, true);
    for (uint32_t i = 0; e == ESP_OK && i < sizeof a->coeff / 2; i++) {
        uint32_t coeff = a->coeff[2 * i] | (uint32_t)a->coeff[2 * i + 1] << 8;
        e = mailbox(RETRO_COEFF, i << 12 | coeff, true);
    }
    int64_t end = esp_timer_get_time() + COMMAND_US;
    while (e == ESP_OK) {
        uint32_t ready, st;
        e = fl_csr_read(RETRO_STAT, &st, 1);
        if (e == ESP_OK && (st & RETRO_FAILED)) e = ESP_FAIL;
        if (e == ESP_OK) e = fl_csr_read(RETRO_ASSETS, &ready, 1);
        if (e != ESP_OK || (ready & 3) == 3) break;
        if (esp_timer_get_time() >= end) { e = ESP_ERR_TIMEOUT; break; }
        vTaskDelay(1);
    }
    return e;
}

static esp_err_t load_locked(FILE *f, const rom_info_t *info, const assets_t *a,
                             void (*progress)(void *, int), void *ctx)
{
    esp_err_t e = check_profile(info->system);
    if (e != ESP_OK) return e;  // never send RETRO commands into another profile
    e = abort_drain();
    uint8_t *buf = NULL;
    if (e == ESP_OK && info->system == ROM_SNES) e = program_assets(a);
    if (e == ESP_OK) {
        uint32_t config[] = {info->system, (uint32_t)info->payload_size,
                             info->map | (info->fast_rom ? 16u : 0u), info->rom_size, info->save_size};
        e = fl_csr_write(RETRO_SYSTEM, config, 5);
    }
    if (e == ESP_OK) {
        buf = malloc(CHUNK);
        if (!buf) e = ESP_ERR_NO_MEM;
    }
    if (e == ESP_OK && fseek(f, (long)info->payload_offset, SEEK_SET)) e = ESP_FAIL;
    if (e == ESP_OK) e = mailbox(RETRO_CTRL, RETRO_KEY | RETRO_BEGIN, true);
    if (e == ESP_OK) e = wait_status(RETRO_READY, RETRO_READY, true, esp_timer_get_time() + COMMAND_US);
    size_t sent = 0;
    int last = -1;
    int64_t end = esp_timer_get_time() + STREAM_US;
    while (e == ESP_OK && sent < info->payload_size) {
        if (esp_timer_get_time() >= end) { e = ESP_ERR_TIMEOUT; break; }
        uint32_t st, space;
        e = fl_csr_read(RETRO_STAT, &st, 1);
        if (e != ESP_OK) break;
        if (st & RETRO_FAILED) { e = ESP_FAIL; break; }
        if (!(st & RETRO_READY)) { vTaskDelay(1); continue; }
        e = fl_csr_read(RETRO_FREE, &space, 1);
        if (e != ESP_OK) break;
        if (space > CHUNK) { e = ESP_ERR_INVALID_RESPONSE; break; }
        if (space <= FIFO_MARGIN) { vTaskDelay(1); continue; }
        size_t k = info->payload_size - sent;
        if (k > space - FIFO_MARGIN) k = space - FIFO_MARGIN;
        if (fread(buf, 1, k, f) != k) { e = ESP_FAIL; break; }
        e = fl_write(FL_CMD_STREAM, 0, buf, k);
        if (e != ESP_OK) break;
        sent += k;
        int pct = (int)(sent * 100 / info->payload_size);
        if (progress && pct != last) { progress(ctx, pct); last = pct; }
        vTaskDelay(1);  // watchdog/yield, also with a continuously empty hardware FIFO
    }
    free(buf);
    if (e == ESP_OK)
        e = wait_status(RETRO_PAYLOAD_DONE, RETRO_PAYLOAD_DONE, true, esp_timer_get_time() + COMMAND_US);
    uint32_t rx = 0;
    if (e == ESP_OK) e = fl_csr_read(RETRO_RX, &rx, 1);
    if (e == ESP_OK && rx != info->payload_size) e = ESP_ERR_INVALID_RESPONSE;
    if (e == ESP_OK) e = mailbox(RETRO_CTRL, RETRO_KEY | RETRO_COMMIT, true);
    if (e == ESP_OK)
        e = wait_status(RETRO_RUNNING | RETRO_DRAIN_BUSY | RETRO_CMD_BUSY,
                        RETRO_RUNNING, true, esp_timer_get_time() + COMMAND_US);
    if (e != ESP_OK) {
        esp_err_t drained = abort_drain();
        if (drained != ESP_OK) return drained;
    }
    return e;
}

esp_err_t retro_load_file(const char *path, void (*progress)(void *, int), void *ctx, uint32_t *ms)
{
    if (ms) *ms = 0;
    if (!path) return ESP_ERR_INVALID_ARG;
    FILE *f = fopen(path, "rb");
    if (!f) return ESP_ERR_NOT_FOUND;
    rom_info_t info;
    assets_t a;
    esp_err_t e = probe(f, path, &info);
    if (e == ESP_OK && info.system == ROM_SNES) e = read_assets(&a);
    if (e == ESP_OK) {
        fl_lock();
        int64_t start = esp_timer_get_time();
        e = load_locked(f, &info, &a, progress, ctx);
        if (fclose(f) && e == ESP_OK) {
            esp_err_t drained = abort_drain();
            e = drained == ESP_OK ? ESP_FAIL : drained;
        }
        f = NULL;
        if (ms) *ms = (uint32_t)((esp_timer_get_time() - start) / 1000);
        fl_unlock();
    }
    if (f && fclose(f) && e == ESP_OK) e = ESP_FAIL;
    return e;
}

esp_err_t retro_reset(void)
{
    fl_lock();
    esp_err_t e = check_profile(ROM_NONE);
    if (e == ESP_OK) e = mailbox(RETRO_CTRL, RETRO_KEY | RETRO_RESET, true);
    fl_unlock();
    return e;
}

esp_err_t retro_stop(void)
{
    fl_lock();
    esp_err_t e = check_profile(ROM_NONE);
    if (e == ESP_OK) e = abort_drain();
    fl_unlock();
    return e;
}
