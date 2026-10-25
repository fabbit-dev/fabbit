#include "lc_app.h"

#include <stdio.h>
#include <string.h>

#include "ui_bitmaps.h"

#define WIPE_MS 240        // смена экрана: развёртка сверху вниз, как на сайте
#define INTRO_MS 800       // заставка при включении: кролик бежит под логотипом
#define INTRO_FRAMES 16
#define SLEEP_MS 120000    // простой: кролик в шапке закрывает глаза
#define TICK_MS 20

typedef enum { ST_INTRO, ST_HOME, ST_GAMES, ST_STUB, ST_LOADING, ST_RUN, ST_ERROR } state_t;

enum { P_RETRO, P_LOGIC, P_N };

static const lc_port_t *P;
static state_t s_st;
static lc_profile_t s_prof[P_N];
static lc_game_t s_games[LC_GAMES_MAX];
static uint8_t s_thumb[LC_THUMB_BYTES];
static int s_ngames, s_psel, s_gsel, s_gtop;
static lc_saved_t s_saved;
static uint32_t s_t0;          // начало экрана: время анимаций
static uint32_t s_last_key;
static bool s_asleep;
static int s_wipe_y = -1;      // строк проявлено; -1: развёртки нет
static uint32_t s_wipe_t0;
static int s_intro_frame;
static char s_err[96];

static const char *TITLE_GAMES = "РЕТРО-КОНСОЛЬ";

// ---------------- общее ----------------

static uint32_t now(void) { return P->now_ms(); }

static const char *plural(int n, const char *one, const char *few, const char *many)
{
    int d = n % 10, h = n % 100;
    if (d == 1 && h != 11) return one;
    if (d >= 2 && d <= 4 && (h < 12 || h > 14)) return few;
    return many;
}

static void profiles_init(void)
{
    s_prof[P_RETRO] = (lc_profile_t){"Ретро-консоль", "РЕТРО-КОНСОЛЬ",
                                     "Схема приставки в ПЛИС, картинка по HDMI", "", &ui_icon_retro, true};
    snprintf(s_prof[P_RETRO].tag, sizeof s_prof[P_RETRO].tag, "%d %s", s_ngames,
             plural(s_ngames, "игра", "игры", "игр"));
    s_prof[P_LOGIC] = (lc_profile_t){"Логический анализатор", "ЛОГИЧЕСКИЙ АНАЛИЗАТОР",
                                     "Цифровые каналы с гребёнки в sigrok", "скоро", &ui_icon_logic, false};
}

// проявить нарисованный в кадре экран развёрткой
static void wipe_start(void)
{
    s_wipe_y = 0;
    s_wipe_t0 = now();
}

static void wipe_step(bool finish)
{
    if (s_wipe_y < 0) return;
    uint32_t dt = now() - s_wipe_t0;
    int y = finish || dt >= WIPE_MS ? UI_H : (int)(UI_H * dt / WIPE_MS) & ~1;
    if ((y > s_wipe_y || y == UI_H) && !ui_reveal(s_wipe_y, y)) return;
    s_wipe_y = y;
    if (y == UI_H) s_wipe_y = -1;
}

// плоскость после перезагрузки ПЛИС пуста: палитра, весь кадр, показ
static void plane_restore(void)
{
    uint32_t pal[16];
    ui_palette(pal);
    P->palette(pal);
    ui_dirty_all();
    ui_flush();
    P->show(true);
}

// ---------------- экраны ----------------

static void select_thumb(void)
{
    for (int i = 0; i < s_ngames; i++) s_games[i].thumb = NULL;
    if (s_ngames && P->thumb && P->thumb(&s_games[s_gsel], s_thumb)) s_games[s_gsel].thumb = s_thumb;
}

static void enter(state_t st, bool wipe)
{
    s_st = st;
    s_t0 = now();
    switch (st) {
    case ST_HOME: lc_home(s_prof, P_N, s_psel); break;
    case ST_GAMES:
        select_thumb();
        lc_games(TITLE_GAMES, s_games, s_ngames, s_gsel, s_gtop);
        break;
    case ST_STUB: lc_stub(&s_prof[s_psel]); break;
    case ST_ERROR: lc_error(TITLE_GAMES, "Игра не запустилась", s_err, 0); break;
    default: return;
    }
    if (wipe) wipe_start();
    else ui_flush();
}

static void games_move(int d)
{
    if (!s_ngames) return;
    int old = s_gsel, top = s_gtop;
    s_gsel += d;
    if (s_gsel < 0) s_gsel = d < -1 ? 0 : s_ngames - 1;  // одиночный шаг по кругу, страница упирается
    if (s_gsel >= s_ngames) s_gsel = d > 1 ? s_ngames - 1 : 0;
    if (s_gsel == old) return;
    if (s_gsel < s_gtop) s_gtop = s_gsel;
    if (s_gsel >= s_gtop + LC_LIST_ROWS) s_gtop = s_gsel - LC_LIST_ROWS + 1;
    select_thumb();
    if (top != s_gtop) {  // прокрутка: список целиком, шапка и подвал на месте
        ui_clip(0, 54, UI_W, 438 - 54);
        lc_games(TITLE_GAMES, s_games, s_ngames, s_gsel, s_gtop);
        ui_clip_reset();
        lc_games_sel(s_games, s_ngames, s_gsel, s_gsel, s_gtop);  // подвал
    } else lc_games_sel(s_games, s_ngames, old, s_gsel, s_gtop);
    ui_flush();
}

typedef struct {
    uint32_t t0;
    char stage[64];
} load_ctx_t;

static void load_progress(void *ctx, const char *stage, int pct)
{
    load_ctx_t *c = ctx;
    char s[64];
    if (pct >= 0) snprintf(s, sizeof s, "%s · %d%%", stage, pct);
    else snprintf(s, sizeof s, "%s", stage);
    if (strcmp(s, c->stage)) {
        snprintf(c->stage, sizeof c->stage, "%s", s);
        lc_loading_stage(s);
    }
    char t[16];
    uint32_t ms = now() - c->t0;
    snprintf(t, sizeof t, "%u,%u с", (unsigned)(ms / 1000), (unsigned)(ms / 100 % 10));
    lc_loading_tick(ms, t);
    ui_flush();
}

static void run_game(void)
{
    if (!s_ngames) return;
    lc_game_t *g = &s_games[s_gsel];
    s_st = ST_LOADING;
    load_ctx_t ctx = {.t0 = now()};
    snprintf(ctx.stage, sizeof ctx.stage, "запуск ядра");
    char sub[80];
    snprintf(sub, sizeof sub, "%s", ctx.stage);
    lc_loading(TITLE_GAMES, g->name, sub, 0);
    wipe_start();
    while (s_wipe_y >= 0) {
        wipe_step(false);
        // Нет связи: развёртка не должна навсегда блокировать запуск и обработку возврата.
        if (now() - ctx.t0 >= 1000) { s_wipe_y = -1; break; }
        P->sleep_ms(TICK_MS);
    }
    s_saved.profile = (uint8_t)s_psel;
    snprintf(s_saved.game, sizeof s_saved.game, "%s", g->name);
    snprintf(s_saved.identity, sizeof s_saved.identity, "%s", g->identity);
    if (P->save) P->save(&s_saved);
    s_err[0] = 0;
    if (P->run(g, load_progress, &ctx, s_err, sizeof s_err)) {
        s_st = ST_RUN;
        return;
    }
    plane_restore();  // ПЛИС могла откатиться в golden с пустой плоскостью
    enter(ST_ERROR, true);
}

// ---------------- заставка ----------------

#define TRACK_X0 200
#define TRACK_X1 440
#define TRACK_Y 347
#define RUN_S 3

static void intro_frame(int i)
{
    int p = i * (TRACK_X1 - TRACK_X0 - 24 * RUN_S) / (INTRO_FRAMES - 1);
    int bx = TRACK_X0 + p;
    ui_fill(TRACK_X0 - 4, TRACK_Y - 18 * RUN_S, TRACK_X1 - TRACK_X0 + 8, 18 * RUN_S + RUN_S + 2, UI_BG);
    ui_fill(TRACK_X0, TRACK_Y, TRACK_X1 - TRACK_X0, RUN_S, UI_MUTED);
    ui_fill(TRACK_X0, TRACK_Y, bx + 12 * RUN_S - TRACK_X0, RUN_S, UI_INK);
    ui_bitmap(&ui_anim_run.f[i % ui_anim_run.n], bx, TRACK_Y - 18 * RUN_S + RUN_S, RUN_S, UI_INK);
    ui_flush();
}

// логотип в плоскости совпадает с заставкой ПЛИС: включение плоскости на экране не видно
static void intro_begin(bool run)
{
    s_st = ST_INTRO;
    s_t0 = now();
    s_intro_frame = run ? 0 : INTRO_FRAMES;
    lc_splash();
    plane_restore();
}

static void intro_end(void) { enter(ST_HOME, true); }

// ---------------- вход ----------------

static void load_games(void)
{
    s_ngames = P->games ? P->games(s_games, LC_GAMES_MAX) : 0;
    if (s_ngames < 0) s_ngames = 0;
    if (s_ngames > LC_GAMES_MAX) s_ngames = LC_GAMES_MAX;
    s_gsel = s_gtop = 0;
    int legacy_match = -1, legacy_count = 0;
    for (int i = 0; i < s_ngames; i++) {
        if (s_saved.identity[0] && !strcmp(s_games[i].identity, s_saved.identity)) s_gsel = i;
        if (!strcmp(s_games[i].name, s_saved.game) && s_games[i].system <= 1) {
            legacy_match = i;
            legacy_count++;
        }
    }
    if (!s_saved.identity[0] && legacy_count == 1) s_gsel = legacy_match;
    if (s_gsel >= LC_LIST_ROWS) s_gtop = s_gsel - LC_LIST_ROWS / 2;
    if (s_gtop > s_ngames - LC_LIST_ROWS) s_gtop = s_ngames > LC_LIST_ROWS ? s_ngames - LC_LIST_ROWS : 0;
    profiles_init();
}

void lc_app_start(const lc_port_t *port, uint8_t *fb, const ui_port_t *ui)
{
    P = port;
    s_asleep = false;
    s_wipe_y = -1;
    ui_init(fb, ui);
    memset(&s_saved, 0, sizeof s_saved);
    if (P->load) P->load(&s_saved);
    s_saved.game[sizeof s_saved.game - 1] = 0;
    s_saved.identity[sizeof s_saved.identity - 1] = 0;
    s_psel = s_saved.profile < P_N ? s_saved.profile : 0;
    s_last_key = now();
    load_games();
    intro_begin(true);
}

void lc_app_attach_running(void)
{
    s_st = ST_RUN;
    s_wipe_y = -1;
    s_asleep = false;
}

void lc_app_back(void)
{
    // ПЛИС только что загрузила golden: на экране его заставка, плоскость пуста
    s_psel = P_RETRO;
    s_asleep = false;
    s_wipe_y = -1;
    load_games();
    s_last_key = now();
    intro_begin(false);
    enter(ST_GAMES, true);
}

bool lc_app_running(void) { return s_st == ST_RUN || s_st == ST_LOADING; }

void lc_app_key(lc_key_t k, bool repeat)
{
    s_last_key = now();
    if (s_asleep) {
        s_asleep = false;
        lc_header_mark(&ui_anim_blink.f[0]);
        ui_flush();
    }
    if (s_wipe_y >= 0) wipe_step(true);
    switch (s_st) {
    case ST_INTRO:
        if (!repeat) intro_end();
        break;
    case ST_HOME:
        if (k == LC_UP || k == LC_DOWN) {
            int old = s_psel;
            s_psel = (s_psel + (k == LC_DOWN ? 1 : P_N - 1)) % P_N;
            lc_home_sel(s_prof, P_N, old, s_psel);
            ui_flush();
        } else if (k == LC_OK && !repeat) {
            if (s_prof[s_psel].ready) enter(ST_GAMES, true);
            else enter(ST_STUB, true);
        }
        break;
    case ST_GAMES:
        if (k == LC_UP) games_move(-1);
        else if (k == LC_DOWN) games_move(1);
        else if (k == LC_LEFT) games_move(-LC_LIST_ROWS);
        else if (k == LC_RIGHT) games_move(LC_LIST_ROWS);
        else if (k == LC_OK && !repeat) run_game();
        else if (k == LC_BACK && !repeat) enter(ST_HOME, true);
        break;
    case ST_STUB:
        if ((k == LC_BACK || k == LC_OK) && !repeat) enter(ST_HOME, true);
        break;
    case ST_ERROR:
        if ((k == LC_BACK || k == LC_OK) && !repeat) enter(ST_GAMES, true);
        break;
    default: break;
    }
}

uint32_t lc_app_tick(void)
{
    if (s_wipe_y >= 0) {
        wipe_step(false);
        return TICK_MS;
    }
    uint32_t t = now() - s_t0;
    switch (s_st) {
    case ST_INTRO: {
        int f = (int)(t * INTRO_FRAMES / INTRO_MS);
        if (f >= INTRO_FRAMES) {
            intro_end();
            break;
        }
        if (f >= s_intro_frame) {
            intro_frame(f);
            s_intro_frame = f + 1;
        }
        return TICK_MS;
    }
    case ST_HOME:
    case ST_GAMES: {
        if (!s_asleep && now() - s_last_key >= SLEEP_MS) {
            s_asleep = true;
            lc_header_mark(&ui_anim_blink.f[2]);  // глаза закрыты
        }
        if (!s_asleep) lc_header_tick(t);
        ui_flush();
        return 40;
    }
    case ST_ERROR:
        lc_header_tick(t);
        {
            const ui_bitmap_t *f = ui_anim_frame(&ui_anim_error, t);
            ui_fill(UI_W / 2 - f->w * 2, 120, f->w * 4, f->h * 4, UI_BG);
            ui_bitmap(f, UI_W / 2 - f->w * 2, 120, 4, UI_INK);
        }
        ui_flush();
        return 40;
    case ST_STUB:
        ui_flush();
        return 100;
    default: return 100;
    }
    return TICK_MS;
}
