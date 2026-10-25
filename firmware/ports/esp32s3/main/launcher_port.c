// Порт лаунчера на стенд: плоскость golden по шине, кнопки, игры из хранилища, NVS.
// Задача menu владеет экраном: golden ведёт лаунчер, ЛА показывает замороженный захват;
// игра оставляет видео своему ядру. После выхода (Fn+Назад, сбой) восстанавливает меню.
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
#include "la_screen.h"
#include "la_capture.h"
#include "la_demo.h"
#include "nes_rom.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "profile_mgr.h"

static const char *TAG = "menu";

#define ROMS "/data/roms"
#define CORE "nes"          // файл ядра в хранилище: /data/nes.fbp
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
static bool demo_requested;

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

static void p_load(lc_saved_t *s) { nvs_get("saved", s, sizeof *s); }
static void p_save(const lc_saved_t *s) { nvs_put("saved", s, sizeof *s); }

// ---------------- игры ----------------

// превью и название рядом с ROM: <имя>.fbi (host/tools/rom_thumbs.py)
typedef struct {
    char magic[4];  // "FBTH"
    uint16_t w, h;
    char title[64];
} __attribute__((packed)) fbi_head_t;

static bool fbi_open(const char *rom, fbi_head_t *hd, FILE **pf)
{
    size_t len = strlen(rom);
    if (len < 4) return false;
    char path[112];
    int plen = snprintf(path, sizeof path, "%.*s.fbi", (int)(len - 4), rom);
    if (plen < 0 || (size_t)plen >= sizeof path) return false;
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
        if (l < 5 || strcasecmp(e->d_name + l - 4, ".nes")) continue;
        lc_game_t *c = &g[n];
        memset(c, 0, sizeof *c);
        if (l + sizeof ROMS + 1 > sizeof c->path) continue;  // путь не влезает
        snprintf(c->path, sizeof c->path, ROMS "/%.*s", (int)(sizeof c->path - sizeof ROMS - 1), e->d_name);
        FILE *f = fopen(c->path, "rb");
        uint8_t h[16];
        nes_info_t info;
        bool ok = f && fread(h, 1, 16, f) == 16 && nes_parse(h, &info) &&
                  fseek(f, 0, SEEK_END) == 0 && ftell(f) >= (long)info.need;
        if (f) fclose(f);
        if (!ok) continue;
        c->mapper = info.mapper;
        c->prg_kb = info.prg_kb;
        c->chr_kb = info.chr_kb;
        snprintf(c->name, sizeof c->name, "%.*s", (int)(l - 4), e->d_name);
        fbi_head_t hd;
        FILE *t;
        if (fbi_open(c->path, &hd, &t)) {
            if (hd.title[0]) snprintf(c->name, sizeof c->name, "%.63s", hd.title);
            fclose(t);
        }
        uint32_t *r = runs_of(c->name, false);
        c->runs = r ? *r : 0;
        n++;
    }
    closedir(d);
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
    r->cb(r->ctx, stage, pct);
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

static bool run_locked(const lc_game_t *g, lc_progress_cb cb, void *ctx, char *err, size_t n)
{
    run_ctx_t r = {cb, ctx};
    esp_err_t e = pm_load_cb(CORE, false, pm_stage, &r);
    if (e != ESP_OK) {
        snprintf(err, n, "ядро NES не запустилось: %s", esp_err_to_name(e));
        fl_id_t id;
        if (fl_id(&id) == ESP_OK && !strcmp(id.magic, "FBPR")) fl_reboot_golden();
        wait_golden(2000);
        return false;
    }
    // дальше плоскости нет: ПЛИС в профиле, на экране NES
    uint32_t ms = 0;
    e = nes_load_file(g->path, NULL, NULL, &ms);
    if (e != ESP_OK) {
        snprintf(err, n, "ROM не загрузился: %s", esp_err_to_name(e));
        fl_reboot_golden();
        wait_golden(3000);
        return false;
    }
    uint32_t *runs = runs_of(g->name, true);
    if (*runs < UINT32_MAX) (*runs)++;
    nvs_put("runs", s_runs, sizeof s_runs);
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

static bool p_run_logic(lc_progress_cb cb, void *ctx, char *err, size_t n)
{
    demo_requested = false;
    la_demo_stop();
    run_ctx_t r = {cb, ctx};
    fl_lock();
    esp_err_t e = pm_load_cb("la", false, pm_stage, &r);
    if (e == ESP_OK) {
        uint32_t magic;
        e = fl_csr_read(64, &magic, 1);
        if (e == ESP_OK && magic != 0x46424d56) e = ESP_ERR_NOT_SUPPORTED;
    }
    if (e != ESP_OK) {
        snprintf(err, n, "%s", esp_err_to_name(e));
        fl_id_t id;
        if (fl_id(&id) == ESP_OK && !strcmp(id.magic, "FBPR")) fl_reboot_golden();
        wait_golden(2000);
    }
    fl_unlock();
    return e == ESP_OK;
}

static bool p_run_demo(lc_progress_cb cb, void *ctx, char *err, size_t n)
{
    if (!p_run_logic(cb, ctx, err, n)) return false;
    esp_err_t e = la_demo_start();
    if (e != ESP_OK) {
        snprintf(err, n, "%s", esp_err_to_name(e));
        fl_reboot_golden();
        wait_golden(2000);
        return false;
    }
    demo_requested = true;
    return true;
}

static const lc_port_t s_port = {
    .now_ms = p_now, .sleep_ms = p_sleep, .palette = p_palette, .show = p_show,
    .games = p_games, .thumb = p_thumb, .run = p_run,
    .load = p_load, .save = p_save,
    .run_logic = p_run_logic,
    .run_demo = p_run_demo,
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

typedef enum { M_WAIT, M_MENU, M_GAME, M_LOGIC } menu_mode_t;

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
    nvs_get("runs", s_runs, sizeof s_runs);
    menu_mode_t m = M_WAIT;
    bool started = false, warned = false;
    for (;;) {
        if (m == M_LOGIC) {
            la_demo_poll();
            if (!la_screen_tick()) { la_demo_stop(); m = M_WAIT; continue; }
            in_event_t event;
            if (in_get(&event, pdMS_TO_TICKS(20))) la_screen_key(&event);
            continue;
        }
        if (m != M_MENU) {
            vTaskDelay(pdMS_TO_TICKS(POLL_MS));
            fl_lock();
            int k = golden_kind();
            if (k == 3) {
                fl_id_t id;
                if (fl_id(&id) == ESP_OK && id.profile == LA_PROFILE_ID) {
                    // UI framebuffer exists even if the ESP started with LA already running.
                    if (!started) ui_init(fb, &s_ui);
                    if (la_screen_attach()) {
                        if (demo_requested) la_screen_demo();
                        demo_requested = false;
                        in_flush(); m = M_LOGIC; fl_unlock(); continue;
                    }
                    demo_requested = false;
                    la_demo_stop();
                }
            }
            // Only the successful LA-screen attach above may retain demo ownership.
            demo_requested = false;
            la_demo_stop();
            if (k == 3 && m == M_WAIT) {
                if (!started) lc_app_attach_running();
                m = M_GAME;
            } else if (k == 2) {
                in_flush();
                if (!started) lc_app_start(&s_port, fb, &s_ui), started = true;
                else { ui_init(fb, &s_ui); lc_app_back(); }
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
    if (e == ESP_ERR_NVS_NO_FREE_PAGES || e == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        e = nvs_flash_init();
    }
    ESP_ERROR_CHECK(e);
    ESP_ERROR_CHECK(xTaskCreatePinnedToCore(task, "menu", 8192, NULL, 5, NULL, 0) == pdPASS
                        ? ESP_OK : ESP_ERR_NO_MEM);
}
