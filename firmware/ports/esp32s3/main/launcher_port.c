// Порт лаунчера на стенд: плоскость golden по шине, кнопки, игры из хранилища, NVS.
// Задача menu владеет экраном: пока в ПЛИС golden, ведёт лаунчер; пока игра, раз в 300 мс читает
// ID и после выхода (Fn+Назад, сбой) возвращает список игр.
#include "launcher_port.h"

#include <ctype.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "fpga_link.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "input.h"
#include "lc_app.h"
#include "nes_rom.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "profile_mgr.h"
#include "rom_port.h"
#include "rom_file.h"
#include "retro_rom.h"

static const char *TAG = "menu";

#define ROMS "/data/roms"
// RETRO profile ID 4: per-console images /data/retro-nes.fbp, retro-md.fbp,
// retro-snes.fbp; the combined /data/retro.fbp is the fallback. Without either, NES
// games run on the standalone NES profile /data/nes.fbp.
#define CORE "retro"
#define NES_CORE "nes"
#define POLL_MS 300
#define RUNS_MAX 64

// ---------------- плоскость ----------------

static bool p_rect(int x, int y, int w, int h, const uint8_t *px, size_t stride)
{
    return fl_osd_rect(x, y, w, h, px, stride) == ESP_OK;
}
static bool p_fill(int x, int y, int w, int h, uint8_t c)
{
    return fl_osd_fill(x, y, w, h, c * 0x11) == ESP_OK;
}
static const ui_port_t s_ui = {p_rect, p_fill};

static void p_palette(const uint32_t rgb[16]) { fl_osd_pal(0, rgb, 16); }
static void p_show(bool on) { fl_osd_show(on); }

static uint32_t p_now(void) { return (uint32_t)(esp_timer_get_time() / 1000); }
static void p_sleep(uint32_t ms) { vTaskDelay(pdMS_TO_TICKS(ms ? ms : 1)); }

// ---------------- запуски и состояние в NVS ----------------

typedef struct {
    uint32_t h;  // хеш имени
    uint32_t n;
} run_t;
static run_t s_runs[RUNS_MAX];
static run_t s_legacy_runs[RUNS_MAX];

static uint32_t name_hash(const char *s) { return fl_crc32(0, (const uint8_t *)s, strlen(s)); }

static void nvs_get(const char *key, void *v, size_t n)
{
    memset(v, 0, n);
    nvs_handle_t h;
    if (nvs_open("launcher", NVS_READONLY, &h) != ESP_OK) return;
    size_t len = n;
    if (nvs_get_blob(h, key, v, &len) != ESP_OK || len != n) memset(v, 0, n);
    nvs_close(h);
}

static void nvs_put(const char *key, const void *v, size_t n)
{
    nvs_handle_t h;
    if (nvs_open("launcher", NVS_READWRITE, &h) != ESP_OK) return;
    nvs_set_blob(h, key, v, n);
    nvs_commit(h);
    nvs_close(h);
}

static uint32_t *runs_of(const char *name, bool add)
{
    uint32_t h = name_hash(name);
    for (int i = 0; i < RUNS_MAX; i++)
        if (s_runs[i].h == h) return &s_runs[i].n;
    if (!add) return NULL;
    int k = 0;  // нет места: вытеснить реже всех запускаемую
    for (int i = 0; i < RUNS_MAX; i++)
        if (s_runs[i].n < s_runs[k].n) k = i;
    s_runs[k] = (run_t){h, 0};
    return &s_runs[k].n;
}

typedef struct { uint8_t profile; char game[64]; } saved_v1_t;
typedef struct {
    uint32_t version;
    lc_saved_t state;
    saved_v1_t legacy_anchor;
} saved_v2_t;

static void p_load(lc_saved_t *s)
{
    memset(s, 0, sizeof *s);
    saved_v1_t old;
    nvs_get("saved", &old, sizeof old);
    s->profile = old.profile;
    memcpy(s->game, old.game, sizeof old.game);
    saved_v2_t v2;
    nvs_get("saved_v2", &v2, sizeof v2);
    // A legacy firmware may have selected another title since v2 last ran.
    // Only reuse the stronger identity while the old prefix still agrees.
    if (v2.version == 2 && v2.state.identity[0] && !memcmp(&v2.legacy_anchor, &old, sizeof old))
        *s = v2.state;
}
static void p_save(const lc_saved_t *s)
{
    saved_v1_t old;
    nvs_get("saved", &old, sizeof old);
    // Old firmware only knows NES title selections. Preserve that selection when
    // a newer firmware runs MD/SNES, including equal-title cartridges.
    if (!s->identity[0] || !strncmp(s->identity, "1:", 2)) {
        old.profile = s->profile;
        memcpy(old.game, s->game, sizeof old.game);
        nvs_put("saved", &old, sizeof old);
    }
    saved_v2_t v2 = {.version = 2, .state = *s, .legacy_anchor = old};
    nvs_put("saved_v2", &v2, sizeof v2);
}

// ---------------- игры ----------------

// превью и название рядом с ROM: <имя>.fbi (host/tools/rom_thumbs.py)
typedef struct {
    char magic[4];  // "FBTH"
    uint16_t w, h;
    char title[64];
} __attribute__((packed)) fbi_head_t;

static bool fbi_open(const char *rom, fbi_head_t *hd, FILE **pf)
{
    char path[112];
    if (!rom_sidecar(rom, ".fbi", path, sizeof path)) return false;
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    if (fread(hd, 1, sizeof *hd, f) != sizeof *hd || memcmp(hd->magic, "FBTH", 4) ||
        hd->w != LC_THUMB_W || hd->h != LC_THUMB_H) {
        fclose(f);
        return false;
    }
    hd->title[sizeof hd->title - 1] = 0;
    *pf = f;
    return true;
}

static int cmp_game(const void *a, const void *b)
{
    return strcasecmp(((const lc_game_t *)a)->name, ((const lc_game_t *)b)->name);
}

static int p_games(lc_game_t *g, int max)
{
    DIR *d = opendir(ROMS);
    if (!d) return 0;
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)) && n < max) {
        size_t l = strlen(e->d_name);
        if (!rom_candidate(e->d_name)) continue;
        lc_game_t *c = &g[n];
        memset(c, 0, sizeof *c);
        if (l + sizeof ROMS + 1 > sizeof c->path) continue;  // путь не влезает
        snprintf(c->path, sizeof c->path, ROMS "/%.*s", (int)(sizeof c->path - sizeof ROMS - 1), e->d_name);
        rom_info_t info;
        // Missing SNES runtime assets must not advertise a launchable cartridge.
        if (retro_preflight(c->path, &info) != ESP_OK) continue;
        c->system = (uint8_t)info.system;
        c->rom_bytes = info.rom_size;
        c->save_bytes = info.save_size;
        c->map = info.map;
        c->fast_rom = info.fast_rom;
        snprintf(c->identity, sizeof c->identity, "%u:%.*s", c->system, (int)l, e->d_name);
        c->mapper = info.nes.mapper;
        c->prg_kb = info.nes.prg_kb;
        c->chr_kb = info.nes.chr_kb;
        const char *dot = strrchr(e->d_name, '.');
        snprintf(c->name, sizeof c->name, "%.*s", (int)(dot - e->d_name), e->d_name);
        fbi_head_t hd;
        FILE *t;
        if (fbi_open(c->path, &hd, &t)) {
            if (hd.title[0]) snprintf(c->name, sizeof c->name, "%.63s", hd.title);
            fclose(t);
        }
        uint32_t *r = runs_of(c->identity, false);
        c->runs = r ? *r : 0;
        n++;
    }
    closedir(d);
    // Legacy title hashes migrate only for an unambiguous NES title; keep the
    // old NVS blob untouched so old firmware still reads its own counters.
    for (int i = 0; i < n; i++) {
        if (g[i].system != ROM_NES || runs_of(g[i].identity, false)) continue;
        int matches = 0;
        for (int j = 0; j < n; j++) if (!strcmp(g[i].name, g[j].name)) matches++;
        if (matches != 1) continue;
        uint32_t h = name_hash(g[i].name);
        for (int j = 0; j < RUNS_MAX; j++) if (s_legacy_runs[j].h == h && s_legacy_runs[j].n) {
            *runs_of(g[i].identity, true) = s_legacy_runs[j].n;
            g[i].runs = s_legacy_runs[j].n;
            break;
        }
    }
    qsort(g, n, sizeof *g, cmp_game);
    return n;
}

static bool p_thumb(const lc_game_t *g, uint8_t *out)
{
    fbi_head_t hd;
    FILE *f;
    if (!fbi_open(g->path, &hd, &f)) return false;
    bool ok = fread(out, 1, LC_THUMB_BYTES, f) == LC_THUMB_BYTES;
    fclose(f);
    return ok;
}

// ---------------- запуск ----------------

typedef struct {
    lc_progress_cb cb;
    void *ctx;
} run_ctx_t;

static void pm_stage(void *ctx, const char *stage, int pct)
{
    run_ctx_t *r = ctx;
    if (r->cb) r->cb(r->ctx, stage, pct);
}

// ждать golden после выхода из профиля или отката, до timeout мс
static bool wait_golden(uint32_t timeout)
{
    int64_t end = esp_timer_get_time() + timeout * 1000LL;
    while (esp_timer_get_time() < end) {
        vTaskDelay(pdMS_TO_TICKS(50));
        fl_tune(16, true);
        fl_id_t id;
        if (fl_id(&id) == ESP_OK && !strcmp(id.magic, "FBGL")) return true;
    }
    return false;
}

static void count_run(const lc_game_t *g, const rom_info_t *info)
{
    char identity[100];
    const char *relative = !strncmp(g->path, ROMS "/", sizeof ROMS) ? g->path + sizeof ROMS : g->path;
    snprintf(identity, sizeof identity, "%u:%s", (unsigned)info->system, relative);
    uint32_t *runs = runs_of(identity, true);
    if (*runs < UINT32_MAX) (*runs)++;
    nvs_put("runs_v2", s_runs, sizeof s_runs);
}

// Per-console image if it is installed, else the combined core.
static const char *core_for(rom_system_t system)
{
    static const char *const image[] = {[ROM_NES] = CORE "-nes", [ROM_MD] = CORE "-md",
                                        [ROM_SNES] = CORE "-snes"};
    if (system > ROM_NONE && system <= ROM_SNES && pm_available(image[system]))
        return image[system];
    return CORE;
}

// NES game with no RETRO image installed: the standalone NES profile.
static bool nes_standalone(rom_system_t system)
{
    return system == ROM_NES && !pm_available(CORE "-nes") && !pm_available(CORE) &&
           pm_available(NES_CORE);
}

static bool run_nes_locked(const lc_game_t *g, run_ctx_t *r, char *err, size_t n)
{
    esp_err_t e = ESP_OK;
    if (!nes_present()) {
        if (retro_present()) {
            e = retro_stop();
            if (e == ESP_OK) e = fl_reboot_golden();
            if (e == ESP_OK && !wait_golden(3000)) e = ESP_ERR_TIMEOUT;
        }
        ESP_LOGI(TAG, "%s: ядро %s", g->name, NES_CORE);
        if (e == ESP_OK) e = pm_load_cb(NES_CORE, false, pm_stage, r);
        if (e == ESP_OK && !nes_present()) e = ESP_ERR_NOT_SUPPORTED;
    }
    uint32_t ms = 0;
    if (e == ESP_OK) e = nes_load_file(g->path, NULL, NULL, &ms);
    if (e != ESP_OK) {
        snprintf(err, n, "ROM не загрузился: %s", esp_err_to_name(e));
        fl_reboot_golden();
        wait_golden(3000);
        return false;
    }
    ESP_LOGI(TAG, "%s: ROM %u мс", g->name, (unsigned)ms);
    return true;
}

static bool run_locked(const lc_game_t *g, lc_progress_cb cb, void *ctx, char *err, size_t n)
{
    rom_info_t info;
    esp_err_t e = retro_preflight(g->path, &info);
    if (e != ESP_OK) {
        snprintf(err, n, "ROM не загрузился: %s", esp_err_to_name(e));
        return false;  // отказ до pm_load и любого recovery reboot
    }
    run_ctx_t r = {cb, ctx};
    if (nes_standalone(info.system)) {
        if (!run_nes_locked(g, &r, err, n)) return false;
        count_run(g, &info);
        return true;
    }
    // A running image that has this console needs no IPROG. Another image is
    // drained and left through golden before the right one is loaded.
    if (!retro_supports(info.system)) {
        if (retro_present()) {
            e = retro_stop();
            if (e == ESP_OK) e = fl_reboot_golden();
            if (e == ESP_OK && !wait_golden(3000)) e = ESP_ERR_TIMEOUT;
        }
        const char *core = core_for(info.system);
        ESP_LOGI(TAG, "%s: ядро %s", g->name, core);
        if (e == ESP_OK) e = pm_load_cb(core, false, pm_stage, &r);
        // The loaded image must really contain the console: never send its ROM blindly.
        if (e == ESP_OK && !retro_supports(info.system)) e = ESP_ERR_NOT_SUPPORTED;
    }
    if (e != ESP_OK) {
        snprintf(err, n, "ROM не загрузился: %s", esp_err_to_name(e));
        fl_id_t id;
        if (fl_id(&id) == ESP_OK && !strcmp(id.magic, "FBPR")) fl_reboot_golden();
        wait_golden(2000);
        return false;
    }
    // дальше плоскости нет: ПЛИС в профиле, на экране NES
    uint32_t ms = 0;
    e = retro_load_file(g->path, NULL, NULL, &ms);
    if (e != ESP_OK) {
        snprintf(err, n, "ROM не загрузился: %s", esp_err_to_name(e));
        fl_reboot_golden();
        wait_golden(3000);
        return false;
    }
    count_run(g, &info);
    ESP_LOGI(TAG, "%s: ROM %u мс", g->name, (unsigned)ms);
    return true;
}

static bool p_run(const lc_game_t *g, lc_progress_cb cb, void *ctx, char *err, size_t n)
{
    fl_lock();
    bool ok = run_locked(g, cb, ctx, err, n);
    fl_unlock();
    return ok;
}

static const lc_port_t s_port = {
    .now_ms = p_now, .sleep_ms = p_sleep, .palette = p_palette, .show = p_show,
    .games = p_games, .thumb = p_thumb, .run = p_run,
    .load = p_load, .save = p_save,
};

// ---------------- задача ----------------

static bool map_key(const in_event_t *e, lc_key_t *k, bool *rep)
{
    if (e->type != IN_PRESS && e->type != IN_REPEAT) return false;
    *rep = e->type == IN_REPEAT;
    if (in_state() & (1u << IN_FN)) return false;  // сочетания с Fn: горячие клавиши игры
    switch (e->key) {
    case IN_UP: *k = LC_UP; return true;
    case IN_DOWN: *k = LC_DOWN; return true;
    case IN_LEFT: *k = LC_LEFT; return true;
    case IN_RIGHT: *k = LC_RIGHT; return true;
    case IN_F2:  // A
    case IN_MENU: *k = LC_OK; return true;
    case IN_F3:  // B
    case IN_BACK: *k = LC_BACK; return true;
    default: return false;
    }
}

typedef enum { M_WAIT, M_MENU, M_GAME } menu_mode_t;

static int golden_kind(void)  // 2: golden с плоскостью, 1: старый golden, 3: профиль, 0: нет ответа
{
    fl_id_t id;
    if (fl_id(&id) != ESP_OK) return 0;
    if (!strcmp(id.magic, "FBGL")) return id.version >= 2 ? 2 : 1;
    if (!strcmp(id.magic, "FBPR")) return 3;
    fl_tune(16, true);  // после загрузки ПЛИС выдача могла сбиться
    return 0;
}

static void task(void *arg)
{
    uint8_t *fb = heap_caps_malloc(UI_FB_SIZE, MALLOC_CAP_SPIRAM);
    if (!fb) {
        ESP_LOGE(TAG, "%s", esp_err_to_name(ESP_ERR_NO_MEM));
        vTaskDelete(NULL);
        return;
    }
    nvs_get("runs", s_legacy_runs, sizeof s_legacy_runs);
    nvs_get("runs_v2", s_runs, sizeof s_runs);
    menu_mode_t m = M_WAIT;
    bool started = false, warned = false;
    for (;;) {
        if (m != M_MENU) {
            vTaskDelay(pdMS_TO_TICKS(POLL_MS));
            fl_lock();
            int k = golden_kind();
            if (k == 3 && m == M_WAIT) {
                if (!started) lc_app_attach_running();
                m = M_GAME;
            } else if (k == 2) {
                in_flush();
                if (!started) lc_app_start(&s_port, fb, &s_ui), started = true;
                else lc_app_back();
                m = M_MENU;
            } else if (k == 1 && !warned) {
                ESP_LOGW(TAG, "golden без плоскости меню (версия 1): меню не показываю");
                warned = true;
            }
            fl_unlock();
            continue;
        }
        fl_lock();
        // Консоль могла сменить профиль после последней проверки: не писать OSD в профиль.
        if (golden_kind() != 2) {
            lc_app_attach_running();
            m = M_GAME;
            fl_unlock();
            continue;
        }
        uint32_t wait = lc_app_tick();
        fl_unlock();
        in_event_t e;
        lc_key_t key;
        bool rep;
        if (in_get(&e, pdMS_TO_TICKS(wait)) && map_key(&e, &key, &rep)) {
            fl_lock();
            if (golden_kind() == 2) lc_app_key(key, rep);
            else lc_app_attach_running();
            fl_unlock();
        }
        if (lc_app_running()) m = M_GAME;
    }
}

void launcher_start(void)
{
    esp_err_t e = nvs_flash_init();
    // Never erase user state automatically on an incompatible/full NVS partition.
    ESP_ERROR_CHECK(e);
    ESP_ERROR_CHECK(xTaskCreatePinnedToCore(task, "menu", 8192, NULL, 5, NULL, 0) == pdPASS
                        ? ESP_OK : ESP_ERR_NO_MEM);
}
