// Real menu/console entry points, real preflight, mocked profile and NES boundaries.
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "esp_err.h"

#define ESP_ERROR_CHECK(expr) assert((expr) == ESP_OK)
static const char *esp_err_to_name(esp_err_t e) { return e == ESP_OK ? "ESP_OK" : "test error"; }

static char temp_dir[512];

// Only the virtual ROM directory is accessible, never the host's /data or devices.
static void local_path(char *out, size_t size, const char *path)
{
    static const char prefix[] = "/data/roms";
    assert(!strncmp(path, prefix, sizeof prefix - 1));
    assert(path[sizeof prefix - 1] == '/' || path[sizeof prefix - 1] == '\0');
    int n = snprintf(out, size, "%s%s", temp_dir, path + sizeof prefix - 1);
    assert(n >= 0 && (size_t)n < size);
}

static FILE *entry_fopen(const char *path, const char *mode)
{
    char local[768];
    local_path(local, sizeof local, path);
    assert(!strcmp(mode, "rb"));
    return fopen(local, mode);
}

static DIR *entry_opendir(const char *path)
{
    char local[768];
    local_path(local, sizeof local, path);
    return opendir(local);
}

// Include to reach static entry points without changing production visibility.
// Unrelated console commands and the menu task are removed by --gc-sections.
#define fopen entry_fopen
#define opendir entry_opendir
#include "../ports/esp32s3/main/launcher_port.c"
#include "../ports/esp32s3/main/cmd_profile.c"
#include "../ports/esp32s3/main/rom_port.c"
#undef opendir
#undef fopen

static struct {
    int pm, backend, present, boot, reboot, csr, id, tune, nvs, progress, locks;
} calls;
static bool menu_entry;
static const char *expected_path;

esp_err_t pm_load_cb(const char *file, bool force, pm_progress_cb cb, void *ctx)
{
    assert(menu_entry && !strcmp(file, "nes") && !force);
    assert(!calls.pm && !calls.backend && !calls.present);
    calls.pm++;
    assert(cb);
    cb(ctx, "core", 100);
    return ESP_OK;
}

esp_err_t nes_load_file(const char *path, void (*cb)(void *, int), void *ctx, uint32_t *ms)
{
    assert(expected_path && !strcmp(path, expected_path));
    assert(!calls.backend && !cb && !ctx);
    // Menu must load exactly one core before the backend; console checks the running core.
    assert(calls.pm == (menu_entry ? 1 : 0));
    assert(calls.present == (menu_entry ? 0 : 1));
    calls.backend++;
    assert(ms);
    *ms = 17;
    return ESP_OK;
}

bool nes_present(void) { calls.present++; return true; }
void fl_lock(void) { calls.locks++; }
void fl_unlock(void) { assert(calls.locks > 0); calls.locks--; }
esp_err_t fl_boot(uint32_t addr) { calls.boot++; return ESP_OK; }
esp_err_t fl_reboot_golden(void) { calls.reboot++; return ESP_OK; }
esp_err_t fl_csr_read(uint8_t idx, uint32_t *values, size_t n)
{
    calls.csr++;
    memset(values, 0, n * sizeof *values);
    return ESP_OK;
}
esp_err_t fl_csr_write(uint8_t idx, const uint32_t *values, size_t n)
{
    calls.csr++;
    return ESP_OK;
}
esp_err_t fl_id(fl_id_t *id)
{
    calls.id++;
    *id = (fl_id_t){.magic = "FBGL"};
    return ESP_OK;
}
esp_err_t fl_tune(uint8_t start, bool fall) { calls.tune++; return ESP_OK; }
// ASan retains the launcher's port table; its unrelated OSD callbacks must not run.
esp_err_t fl_osd_rect(uint16_t x, uint16_t y, uint16_t w, uint16_t h,
                      const uint8_t *pixels, size_t stride)
{
    assert(!"unexpected OSD access");
    return ESP_FAIL;
}
esp_err_t fl_osd_fill(uint16_t x, uint16_t y, uint16_t w, uint16_t h, uint8_t color)
{
    assert(!"unexpected OSD access");
    return ESP_FAIL;
}
esp_err_t fl_osd_pal(uint8_t first, const uint32_t *rgb, size_t n)
{
    assert(!"unexpected OSD access");
    return ESP_FAIL;
}
esp_err_t fl_osd_show(bool on) { assert(!"unexpected OSD access"); return ESP_FAIL; }
int64_t esp_timer_get_time(void) { static int64_t us; return us += 1000000; }
void vTaskDelay(TickType_t ticks) {}
uint32_t fl_crc32(uint32_t crc, const uint8_t *bytes, size_t n)
{
    // Only a stable name hash is needed; the actual CRC is covered by test_loader.
    while (n--) crc = crc * 33 + *bytes++;
    return crc;
}
esp_err_t nvs_open(const char *name, nvs_open_mode_t mode, nvs_handle_t *handle)
{
    calls.nvs++;
    return ESP_ERR_NOT_FOUND;
}
esp_err_t nvs_set_blob(nvs_handle_t handle, const char *key, const void *value, size_t size)
{
    assert(!"NVS should not be open in this test");
    return ESP_FAIL;
}
esp_err_t nvs_commit(nvs_handle_t handle) { assert(!"NVS should not be open"); return ESP_FAIL; }
void nvs_close(nvs_handle_t handle) { assert(!"NVS should not be open"); }

static void progress(void *ctx, const char *stage, int pct)
{
    assert(ctx == &calls && !strcmp(stage, "core") && pct == 100);
    assert(calls.pm == 1 && !calls.backend);
    calls.progress++;
}

static void reset_calls(bool menu, const char *path)
{
    assert(!calls.locks);
    memset(&calls, 0, sizeof calls);
    menu_entry = menu;
    expected_path = path;
}

static void no_hardware(void)
{
    assert(!calls.boot && !calls.reboot && !calls.csr && !calls.id && !calls.tune);
}

static void no_effects(void)
{
    no_hardware();
    assert(!calls.pm && !calls.backend && !calls.present && !calls.nvs && !calls.progress);
}

static void fixture(const char *name, const uint8_t header[16], size_t size)
{
    char path[768];
    int n = snprintf(path, sizeof path, "%s/%s", temp_dir, name);
    assert(n >= 0 && (size_t)n < sizeof path);
    FILE *f = fopen(path, "wb");
    assert(f);
    size_t head_size = size < 16 ? size : 16;
    assert(fwrite(header, 1, head_size, f) == head_size);
    if (size > head_size) {
        assert(!fseek(f, (long)size - 1, SEEK_SET));
        assert(fputc(0, f) != EOF);
    }
    assert(!fclose(f));
}

static void rejected_entries(const char *name)
{
    lc_game_t game = {0};
    snprintf(game.path, sizeof game.path, "/data/roms/%s", name);
    char err[128] = "";
    reset_calls(true, NULL);
    assert(!run_locked(&game, progress, &calls, err, sizeof err));
    assert(err[0]);
    no_effects();

    // Exercise the console's bare-name path construction too.
    char *argv[] = {"rom", (char *)name};
    reset_calls(false, NULL);
    assert(cmd_rom(2, argv) != 0);
    no_effects();
}

static void accepted_menu(const lc_game_t *game)
{
    reset_calls(true, game->path);
    char err[128] = "";
    assert(run_locked(game, progress, &calls, err, sizeof err));
    assert(!err[0] && calls.pm == 1 && calls.backend == 1 && calls.progress == 1);
    assert(!calls.present && calls.nvs == 1);
    no_hardware();
}

static void accepted_console(const char *arg, const char *path)
{
    char *argv[] = {"rom", (char *)arg};
    reset_calls(false, path);
    assert(cmd_rom(2, argv) == 0);
    assert(calls.present == 1 && calls.backend == 1 && !calls.pm && !calls.nvs);
    no_hardware();
}

int main(void)
{
    const char *base = getenv("TMPDIR");
    if (!base || !*base) base = "/tmp";
    int n = snprintf(temp_dir, sizeof temp_dir, "%s/fabbit-entries-XXXXXX", base);
    assert(n >= 0 && (size_t)n < sizeof temp_dir && mkdtemp(temp_dir));

    uint8_t nes[16] = {'N', 'E', 'S', 0x1a, 1};
    uint8_t bad[16] = {0};
    const char *invalid[] = {"bad.nes", "short.nes", "truncated.nes", "trainer.nes",
                             "cart.md", "cart.GEN", "cart.sfc", "cart.SMC", "unknown.bin",
                             "missing.nes"};
    fixture("valid.nes", nes, 16400);
    fixture("alpha.NES", nes, 16400);
    fixture("magic.bin", nes, 16400);
    fixture("bad.nes", bad, 16400);
    fixture("short.nes", nes, 8);
    fixture("truncated.nes", nes, 16399);
    nes[6] = 4;
    fixture("trainer.nes", nes, 16912);
    for (size_t i = 4; i < 9; i++) fixture(invalid[i], bad, 16400);

    // NES-only directory scope is intentional: magic.bin is valid for console,
    // but menu candidates must also have a .nes suffix (case insensitive).
    lc_game_t games[16];
    reset_calls(true, NULL);
    assert(p_games(games, 16) == 2);
    assert(!strcmp(games[0].path, "/data/roms/alpha.NES"));
    assert(!strcmp(games[1].path, "/data/roms/valid.nes"));
    assert(!strcmp(games[0].name, "alpha") && !strcmp(games[1].name, "valid"));
    for (int i = 0; i < 2; i++) {
        assert(games[i].mapper == 0 && games[i].prg_kb == 16 && games[i].chr_kb == 0);
        assert(!games[i].runs);
    }
    no_effects();

    for (size_t i = 0; i < sizeof invalid / sizeof *invalid; i++) rejected_entries(invalid[i]);
    // A bare console name must append .nes before the same preflight.
    rejected_entries("truncated");
    accepted_menu(&games[1]);
    accepted_console("valid", "/data/roms/valid.nes");
    accepted_console("magic.bin", "/data/roms/magic.bin");
    accepted_console("/data/roms/magic.bin", "/data/roms/magic.bin");

    const char *valid[] = {"valid.nes", "alpha.NES", "magic.bin"};
    char path[768];
    for (size_t i = 0; i < sizeof valid / sizeof *valid; i++) {
        snprintf(path, sizeof path, "%s/%s", temp_dir, valid[i]);
        assert(!unlink(path));
    }
    for (size_t i = 0; i + 1 < sizeof invalid / sizeof *invalid; i++) {
        snprintf(path, sizeof path, "%s/%s", temp_dir, invalid[i]);
        assert(!unlink(path));
    }
    assert(!rmdir(temp_dir));
    puts("ok ROM entries: real NES-only menu, preflight before effects, core/backend order, console suffix/magic");
    return 0;
}
