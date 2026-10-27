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
#define retro_preflight actual_retro_preflight
#define retro_present actual_retro_present
#define retro_supports actual_retro_supports
#define retro_stop actual_retro_stop
#define retro_load_file actual_retro_load_file
#define retro_reset actual_retro_reset
#include "../ports/esp32s3/components/retro_rom/retro_rom.c"
#undef retro_reset
#undef retro_load_file
#undef retro_stop
#undef retro_supports
#undef retro_present
#undef retro_preflight
#undef opendir
#undef fopen

static struct {
    int pm, backend, present, boot, reboot, csr, id, tune, nvs, progress, locks, stop;
} calls;
// Image model: caps of the RETRO image active after the last pm_load (0: golden).
static unsigned active_caps, installed;  // installed: bit per system has retro-<sys>.fbp
static unsigned loaded_caps(const char *file)
{
    if (!strcmp(file, "retro")) return 7;
    if (!strcmp(file, "retro-nes")) return 1u << (ROM_NES - 1);
    if (!strcmp(file, "retro-md")) return 1u << (ROM_MD - 1);
    if (!strcmp(file, "retro-snes")) return 1u << (ROM_SNES - 1);
    assert(!"unexpected profile");
    return 0;
}
static const char *expected_core = "retro";
static bool menu_entry;
static const char *expected_path;
static bool nvs_enabled;
static saved_v1_t stored_old;
static saved_v2_t stored_new;

esp_err_t pm_load_cb(const char *file, bool force, pm_progress_cb cb, void *ctx)
{
    assert(menu_entry && !strcmp(file, expected_core) && !force);
    assert(!calls.pm && !calls.backend && !active_caps);  // only from golden
    calls.pm++;
    assert(cb);
    cb(ctx, "core", 100);
    active_caps = loaded_caps(file);
    return ESP_OK;
}
bool pm_available(const char *file)
{
    for (int s = ROM_NES; s <= ROM_SNES; s++)
        if ((installed >> s) & 1 && !strcmp(file, (const char *[]){0, "retro-nes", "retro-md",
                                                                     "retro-snes"}[s]))
            return true;
    return false;
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
bool retro_present(void) { return active_caps != 0; }
bool retro_supports(rom_system_t system)
{
    return system != ROM_NONE && (active_caps >> (system - 1)) & 1;
}
esp_err_t retro_stop(void) { assert(active_caps); calls.stop++; return ESP_OK; }
esp_err_t retro_preflight(const char *path, rom_info_t *info) { return actual_retro_preflight(path, info); }
esp_err_t retro_load_file(const char *path, void (*cb)(void *, int), void *ctx, uint32_t *ms)
{
    assert(menu_entry && expected_path && !strcmp(path, expected_path));
    assert(!cb && !ctx && retro_present());
    calls.backend++;
    *ms = 17;
    return ESP_OK;
}
void fl_lock(void) { calls.locks++; }
void fl_unlock(void) { assert(calls.locks > 0); calls.locks--; }
esp_err_t fl_boot(uint32_t addr) { calls.boot++; return ESP_OK; }
esp_err_t fl_reboot_golden(void) { calls.reboot++; active_caps = 0; return ESP_OK; }
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
    *id = active_caps ? (fl_id_t){.magic = "FBPR", .profile = 4} : (fl_id_t){.magic = "FBGL", .version = 2};
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
    *handle = 1;
    return nvs_enabled ? ESP_OK : ESP_ERR_NOT_FOUND;
}
esp_err_t nvs_get_blob(nvs_handle_t handle, const char *key, void *value, size_t *size)
{
    const void *data;
    size_t n;
    if (!strcmp(key, "saved")) { data = &stored_old; n = sizeof stored_old; }
    else if (!strcmp(key, "saved_v2")) { data = &stored_new; n = sizeof stored_new; }
    else return ESP_ERR_NOT_FOUND;
    if (*size < n) return ESP_ERR_INVALID_SIZE;
    memcpy(value, data, n); *size = n;
    return ESP_OK;
}
esp_err_t nvs_set_blob(nvs_handle_t handle, const char *key, const void *value, size_t size)
{
    assert(nvs_enabled);
    if (!strcmp(key, "saved")) { assert(size == sizeof stored_old); memcpy(&stored_old, value, size); }
    else if (!strcmp(key, "saved_v2")) { assert(size == sizeof stored_new); memcpy(&stored_new, value, size); }
    else assert(!"unexpected NVS write");
    return ESP_OK;
}
esp_err_t nvs_commit(nvs_handle_t handle) { assert(nvs_enabled); return ESP_OK; }
void nvs_close(nvs_handle_t handle) { assert(nvs_enabled); }

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

static void full_fixture(const char *name, const uint8_t *data, size_t size)
{
    char path[768]; snprintf(path, sizeof path, "%s/%s", temp_dir, name);
    FILE *f = fopen(path, "wb");
    assert(f && fwrite(data, 1, size, f) == size && !fclose(f));
}

static void mixed_catalog(void)
{
    uint8_t data[65536] = {0};
    memcpy(data + 0x100, "SEGA MEGA DRIVE ", 16);
    data[1] = 0xff; data[2] = 0xff; // SP 0x00ffff00
    data[6] = 2; // PC 0x200
    data[0x1a6] = 0xff; data[0x1a7] = 0xff;
    data[0x1f0] = 'U';
    full_fixture("valid.gen", data, sizeof data); // duplicate title, distinct identity
    memset(data, 0, sizeof data);
    uint8_t *h = data + 0x7fc0;
    h[0x15] = 0x20; h[0x17] = 6; h[0x19] = 1;
    h[0x1c] = 0xcb; h[0x1d] = 0xed; h[0x1e] = 0x34; h[0x1f] = 0x12; h[0x3d] = 0x80;
    full_fixture("snes.sfc", data, sizeof data);
    lc_game_t games[16];
    reset_calls(true, NULL);
    assert(p_games(games, 16) == 4); // missing assets: SNES omitted
    lc_game_t game = {0}; strcpy(game.path, "/data/roms/snes.sfc");
    char err[128];
    assert(!run_locked(&game, progress, &calls, err, sizeof err));
    no_effects(); // before pm_load, ID, CSR, BOOT, or recovery
    for (unsigned i = 0; i < 64; i++) data[i] = i;
    full_fixture("snes.ipl", data, 64);
    memset(data, 0, 1024); data[0] = 1;
    full_fixture("snes.gauss", data, 1024);
    memset(s_runs, 0, sizeof s_runs);
    s_legacy_runs[0] = (run_t){name_hash("alpha"), 7};
    s_legacy_runs[1] = (run_t){name_hash("valid"), 9};
    assert(p_games(games, 16) == 5);
    int systems = 0;
    for (int i = 0; i < 5; i++) {
        systems |= 1 << games[i].system;
        assert(games[i].identity[0]);
        if (!strcmp(games[i].name, "alpha")) assert(games[i].runs == 7);
        if (!strcmp(games[i].name, "valid")) assert(games[i].runs == 0); // ambiguous legacy title
        if (games[i].system == ROM_MD || games[i].system == ROM_SNES) assert(games[i].rom_bytes == 65536);
    }
    assert(systems == ((1 << ROM_NES) | (1 << ROM_MD) | (1 << ROM_SNES)));
    char sidecar[100];
    assert(rom_sidecar("/data/roms/valid.gen", ".fbi", sidecar, sizeof sidecar));
    assert(!strcmp(sidecar, "/data/roms/valid.fbi"));
    assert(rom_sidecar("x.MD", ".fbi", sidecar, sizeof sidecar) && !strcmp(sidecar, "x.fbi"));
    assert(!rom_sidecar("long.gen", ".fbi", sidecar, 4));
    const char *files[] = {"valid.gen", "snes.sfc", "snes.ipl", "snes.gauss"};
    for (size_t i = 0; i < sizeof files / sizeof *files; i++) {
        char path[768]; snprintf(path, sizeof path, "%s/%s", temp_dir, files[i]); assert(!unlink(path));
    }
}

static void state_compat(void)
{
    nvs_enabled = true;
    strcpy(stored_old.game, "valid");
    lc_saved_t state;
    p_load(&state);
    assert(!strcmp(state.game, "valid") && !state.identity[0]);
    strcpy(state.identity, "1:valid.nes"); p_save(&state);
    assert(!strcmp(stored_old.game, "valid"));
    p_load(&state); assert(!strcmp(state.identity, "1:valid.nes"));
    strcpy(state.game, "MD title"); strcpy(state.identity, "2:cart.gen");
    p_save(&state);
    assert(!strcmp(stored_old.game, "valid"));
    p_load(&state); assert(!strcmp(state.identity, "2:cart.gen") && !strcmp(state.game, "MD title"));
    strcpy(stored_old.game, "alpha"); // downgraded firmware selected another title
    p_load(&state); assert(!strcmp(state.game, "alpha") && !state.identity[0]);
    nvs_enabled = false;
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
    active_caps = 0;
}

// Per-console images: pick retro-<sys> when installed, keep a running image that
// already has the console, leave another image through stop+golden first.
static void per_console_images(const lc_game_t *nes_game)
{
    char err[128] = "";
    installed = 1u << ROM_NES;
    expected_core = "retro-nes";
    reset_calls(true, nes_game->path);
    assert(run_locked(nes_game, progress, &calls, err, sizeof err));
    assert(calls.pm == 1 && calls.backend == 1 && !calls.stop && !calls.reboot);
    assert(active_caps == 1);
    // Same console again: hot image, no IPROG.
    reset_calls(true, nes_game->path);
    assert(run_locked(nes_game, progress, &calls, err, sizeof err));
    assert(!calls.pm && calls.backend == 1 && !calls.stop && !calls.reboot);
    // MD-only image active, NES requested: drain, golden, then the NES image.
    active_caps = 1u << (ROM_MD - 1);
    reset_calls(true, nes_game->path);
    assert(run_locked(nes_game, progress, &calls, err, sizeof err));
    assert(calls.stop == 1 && calls.reboot == 1 && calls.pm == 1 && calls.backend == 1);
    assert(active_caps == 1);
    // Combined image remains valid for every console.
    active_caps = 7;
    reset_calls(true, nes_game->path);
    assert(run_locked(nes_game, progress, &calls, err, sizeof err));
    assert(!calls.pm && !calls.stop && !calls.reboot && calls.backend == 1);
    // Not installed: fall back to the combined profile.
    active_caps = 0;
    installed = 0;
    expected_core = "retro";
    reset_calls(true, nes_game->path);
    assert(run_locked(nes_game, progress, &calls, err, sizeof err));
    assert(calls.pm == 1 && active_caps == 7);
    active_caps = 0;
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
    const char *unsupported[] = {"mapper-extension.nes", "vs-system.nes",
                                 "playchoice.nes", "extended-console.nes", "pal-only.nes"};
    for (size_t i = 0; i < sizeof unsupported / sizeof *unsupported; i++) {
        uint8_t header[16] = {'N', 'E', 'S', 0x1a, 1};
        header[7] = 8;
        if (i == 0) header[8] = 4;
        else if (i < 4) header[7] |= (uint8_t)i;
        else header[12] = 1;
        fixture(unsupported[i], header, 16400);
    }

    // Candidate suffixes are hints; actual content validation controls inclusion.
    lc_game_t games[16];
    reset_calls(true, NULL);
    assert(p_games(games, 16) == 3);
    assert(!strcmp(games[0].path, "/data/roms/alpha.NES"));
    assert(!strcmp(games[2].path, "/data/roms/valid.nes"));
    assert(!strcmp(games[0].name, "alpha") && !strcmp(games[2].name, "valid"));
    for (int i = 0; i < 3; i++) {
        assert(games[i].mapper == 0 && games[i].prg_kb == 16 && games[i].chr_kb == 0);
        assert(!games[i].runs);
    }
    no_effects();

    for (size_t i = 0; i < sizeof invalid / sizeof *invalid; i++) rejected_entries(invalid[i]);
    for (size_t i = 0; i < sizeof unsupported / sizeof *unsupported; i++)
        rejected_entries(unsupported[i]);
    // A bare console name must append .nes before the same preflight.
    rejected_entries("truncated");
    accepted_menu(&games[2]);
    active_caps = 7;
    reset_calls(true, games[2].path);
    char err[128] = "";
    assert(p_run(&games[2], progress, &calls, err, sizeof err));
    assert(!calls.pm && !calls.boot && !calls.reboot && calls.backend == 1 && !calls.locks);
    active_caps = 0;
    per_console_images(&games[2]);
    accepted_console("valid", "/data/roms/valid.nes");
    accepted_console("magic.bin", "/data/roms/magic.bin");
    accepted_console("/data/roms/magic.bin", "/data/roms/magic.bin");
    mixed_catalog();
    state_compat();

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
    for (size_t i = 0; i < sizeof unsupported / sizeof *unsupported; i++) {
        snprintf(path, sizeof path, "%s/%s", temp_dir, unsupported[i]);
        assert(!unlink(path));
    }
    assert(!rmdir(temp_dir));
    puts("ok ROM entries: mixed catalog/metadata/identities, preflight before effects/assets, hot core, legacy NVS");
    puts("ok per-console images: retro-<sys> chosen, hot reuse, stop+golden switch, combined fallback");
    return 0;
}
