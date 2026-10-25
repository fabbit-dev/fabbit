#include "lc_view.h"

#include <stdio.h>
#include <string.h>

#include "ui_bitmaps.h"

#define W UI_W
#define H UI_H
#define TOP 54      // под шапкой
#define BOTTOM 438  // над подвалом
#define MARK_X 16
#define MARK_Y 8

// ---------------- шапка и подвал ----------------

static const ui_bitmap_t *s_mark;  // кадр кролика, который сейчас на экране

static void draw_mark(const ui_bitmap_t *f)
{
    ui_fill(MARK_X, MARK_Y, f->w * 2, f->h * 2, UI_BG);
    ui_bitmap(f, MARK_X, MARK_Y, 2, UI_INK);
    s_mark = f;
}

void lc_header(const char *title, uint32_t t_ms)
{
    ui_fill(0, 0, W, TOP, UI_BG);
    draw_mark(ui_anim_frame(&ui_anim_blink, t_ms));
    ui_text(&ui_font_mono20b, 56, 15, title, UI_INK, UI_LEFT);
    const ui_bitmap_t *ic[] = {&ui_icon_hdmi, &ui_icon_usb};  // SD на стенде нет
    int x = W - 16;
    for (int i = 0; i < 2; i++) {
        x -= 32;
        ui_bitmap(ic[i], x, 12, 2, UI_T3);
        x -= 8;
    }
    ui_fill(0, 52, W, 2, UI_INK);
}

void lc_header_mark(const ui_bitmap_t *f) { draw_mark(f); }

bool lc_header_tick(uint32_t t_ms)
{
    const ui_bitmap_t *f = ui_anim_frame(&ui_anim_blink, t_ms);
    if (f == s_mark) return false;
    draw_mark(f);
    return true;
}

void lc_splash(void)
{
    ui_fill(0, 0, W, H, UI_BG);
    ui_bitmap(&ui_logo, 120, 182, 5, UI_INK);
}

void lc_footer(const lc_hint_t *keys, int n, const char *right)
{
    ui_fill(0, BOTTOM, W, H - BOTTOM, UI_BG);
    ui_fill(0, BOTTOM, W, 2, UI_INK);
    int x = 16;
    for (int i = 0; i < n; i++) {
        int kw = ui_text_width(&ui_font_mono15b, keys[i].key);
        ui_fill(x, 448, kw + 8, 22, UI_INK);
        ui_text(&ui_font_mono15b, x + 4, 450, keys[i].key, UI_BG, UI_LEFT);
        x += kw + 16;
        x += ui_text(&ui_font_mono15, x, 450, keys[i].what, UI_T2, UI_LEFT) + 24;
    }
    if (right) ui_text(&ui_font_mono15b, W - 16, 450, right, UI_INK, UI_RIGHT);
}

// ---------------- профили ----------------

#define CARD_X 16
#define CARD_W (W - 32)
#define CARD_H 88
#define CARD_Y0 76
#define CARD_STEP 104

void lc_home_card(const lc_profile_t *all, int i, bool sel)
{
    const lc_profile_t *p = &all[i];
    int y = CARD_Y0 + i * CARD_STEP;
    uint8_t fg = sel ? UI_BG : UI_INK, sub = sel ? UI_MUTED : UI_T3;
    if (sel) ui_fill(CARD_X, y, CARD_W, CARD_H, UI_INK);
    else {
        ui_fill(CARD_X, y, CARD_W, CARD_H, UI_BG);
        ui_frame(CARD_X, y, CARD_W, CARD_H, 2, UI_LINE);
    }
    ui_bitmap(p->icon, 36, y + 20, 3, fg);
    ui_text(&ui_font_mono24b, 108, y + 16, p->name, fg, UI_LEFT);
    ui_text(&ui_font_mono15, 108, y + 52, p->desc, sub, UI_LEFT);
    int tw = ui_text_width(&ui_font_mono15b, p->tag);
    int tx = W - 36 - 16 - tw;
    ui_frame(tx, y + 16, tw + 16, 24, 2, fg);
    ui_text(&ui_font_mono15b, tx + 8, y + 18, p->tag, fg, UI_LEFT);
}

static void home_footer(int n, int sel)
{
    char right[24];
    snprintf(right, sizeof right, "%d/%d", sel + 1, n);
    static const lc_hint_t keys[] = {{"▲▼", "профиль"}, {"A", "открыть"}};
    lc_footer(keys, 2, right);
}

void lc_home_sel(const lc_profile_t *p, int n, int old, int sel)
{
    lc_home_card(p, old, false);
    lc_home_card(p, sel, true);
    home_footer(n, sel);
}

void lc_home(const lc_profile_t *p, int n, int sel)
{
    ui_fill(0, 0, W, H, UI_BG);
    lc_header("ПРОФИЛИ", 0);
    for (int i = 0; i < n; i++) lc_home_card(p, i, i == sel);
    int y = CARD_Y0 + n * CARD_STEP;
    if (y + CARD_H <= BOTTOM - 8) {
        ui_hline_dash(CARD_X, y, CARD_W, 2, 6, 6, UI_MUTED);
        ui_hline_dash(CARD_X, y + CARD_H - 2, CARD_W, 2, 6, 6, UI_MUTED);
        ui_text(&ui_font_mono15, W / 2, y + 34, "здесь появятся новые профили", UI_MUTED, UI_CENTER);
    }
    home_footer(n, sel);
}

// ---------------- список игр ----------------

#define LIST_X 16
#define LIST_W 336
#define ROW_Y0 66
#define ROW_H 44
#define PREV_X 376
#define PREV_Y 66

static void games_row(const lc_game_t *g, int i, int top, bool sel)
{
    int y = ROW_Y0 + (i - top) * ROW_H;
    char s[64];
    ui_fill(LIST_X, y, LIST_W, 34, sel ? UI_INK : UI_BG);
    ui_ellipsize(&ui_font_mono18b, g[i].name, LIST_W - 24, s, sizeof s);
    ui_text(sel ? &ui_font_mono18b : &ui_font_mono18, LIST_X + 12, y + 6, s, sel ? UI_BG : UI_INK,
            UI_LEFT);
}

// имена частых мапперов iNES (nesdev wiki, «Mapper»)
static const char *mapper_name(uint8_t m)
{
    switch (m) {
    case 0: return "NROM";
    case 1: return "MMC1";
    case 2: return "UxROM";
    case 3: return "CNROM";
    case 4: return "MMC3";
    case 5: return "MMC5";
    case 7: return "AxROM";
    case 9: return "MMC2";
    case 10: return "MMC4";
    case 66: return "GxROM";
    default: return NULL;
    }
}

static void games_info(const lc_game_t *g, int n, int sel, int top)
{
    // полоса прокрутки
    ui_fill(360, ROW_Y0, 2, LC_LIST_ROWS * ROW_H - 10, UI_LINE);
    if (n > LC_LIST_ROWS) {
        int h = (LC_LIST_ROWS * ROW_H - 10) * LC_LIST_ROWS / n;
        int y = ROW_Y0 + (LC_LIST_ROWS * ROW_H - 10 - h) * top / (n - LC_LIST_ROWS);
        ui_fill(360, y, 2, h, UI_INK);
    } else ui_fill(360, ROW_Y0, 2, LC_LIST_ROWS * ROW_H - 10, UI_INK);

    // превью
    int px = PREV_X, py = PREV_Y, pw = LC_THUMB_W + 8, ph = LC_THUMB_H + 8;
    ui_frame(px - 2, py - 2, pw + 4, ph + 4, 2, UI_INK);
    ui_fill(px, py, pw, ph, UI_BG);
    const lc_game_t *c = &g[sel];
    if (c->thumb) {
        uint8_t *fb = ui_fb();
        for (int j = 0; j < LC_THUMB_H; j++)
            memcpy(fb + (py + 4 + j) * UI_STRIDE + (px + 4) / 2, c->thumb + j * (LC_THUMB_W / 2),
                   LC_THUMB_W / 2);
        ui_dirty(px + 4, py + 4, LC_THUMB_W, LC_THUMB_H);
    } else {
        ui_bitmap(&ui_icon_retro, px + pw / 2 - 32, py + ph / 2 - 40, 4, UI_MUTED);
        ui_text(&ui_font_mono15, px + pw / 2, py + ph / 2 + 36, "нет превью", UI_MUTED, UI_CENTER);
    }

    // данные ROM
    char v[4][24];
    const char *mn = mapper_name(c->mapper);
    if (mn) snprintf(v[0], sizeof v[0], "%u · %s", c->mapper, mn);
    else snprintf(v[0], sizeof v[0], "%u", c->mapper);
    snprintf(v[1], sizeof v[1], "%u КБ", c->prg_kb);
    snprintf(v[2], sizeof v[2], "%u КБ", c->chr_kb);
    snprintf(v[3], sizeof v[3], "%lu", (unsigned long)c->runs);
    static const char *k[4] = {"маппер", "PRG", "CHR", "запусков"};
    int y = py + ph + 14;
    ui_fill(px - 2, y, pw + 4, 4 * 26, UI_BG);
    for (int i = 0; i < 4; i++, y += 26) {
        ui_text(&ui_font_mono15, px, y, k[i], UI_T3, UI_LEFT);
        ui_text(&ui_font_mono15b, px + pw, y, v[i], UI_INK, UI_RIGHT);
    }
}

static void games_footer(int n, int sel)
{
    char right[24];
    snprintf(right, sizeof right, "%d/%d", n ? sel + 1 : 0, n);
    static const lc_hint_t keys[] = {{"A", "играть"}, {"B", "назад"}, {"Fn+Назад", "выход из игры"}};
    lc_footer(keys, 3, right);
}

void lc_games(const char *title, const lc_game_t *g, int n, int sel, int top)
{
    ui_fill(0, 0, W, H, UI_BG);
    lc_header(title, 0);
    if (!n) {
        ui_text(&ui_font_mono18b, W / 2, 200, "Игр нет", UI_INK, UI_CENTER);
        ui_text(&ui_font_mono15, W / 2, 236, "положи файлы .nes в папку roms", UI_T3, UI_CENTER);
        static const lc_hint_t keys[] = {{"B", "назад"}};
        lc_footer(keys, 1, NULL);
        return;
    }
    for (int i = top; i < n && i < top + LC_LIST_ROWS; i++) games_row(g, i, top, i == sel);
    games_info(g, n, sel, top);
    games_footer(n, sel);
}

void lc_games_sel(const lc_game_t *g, int n, int old, int sel, int top)
{
    if (old >= top && old < top + LC_LIST_ROWS) games_row(g, old, top, false);
    games_row(g, sel, top, true);
    games_info(g, n, sel, top);
    games_footer(n, sel);
}

// ---------------- загрузка, заглушка, ошибка ----------------

#define PROG_S 4
#define PROG_Y 180

static const ui_bitmap_t *s_prog;

void lc_loading(const char *title, const char *game, const char *sub, uint32_t t_ms)
{
    ui_fill(0, 0, W, H, UI_BG);
    lc_header(title, t_ms);
    s_prog = NULL;
    lc_loading_tick(t_ms, "");
    char s[64];
    ui_ellipsize(&ui_font_mono24b, game, W - 64, s, sizeof s);
    ui_text(&ui_font_mono24b, W / 2, 300, s, UI_INK, UI_CENTER);
    lc_loading_stage(sub);
}

void lc_loading_stage(const char *sub)
{
    ui_fill(0, 336, W, 24, UI_BG);
    ui_text(&ui_font_mono15, W / 2, 338, sub, UI_T3, UI_CENTER);
}

void lc_loading_tick(uint32_t t_ms, const char *right)
{
    const ui_bitmap_t *f = ui_anim_frame(&ui_anim_progress, t_ms);
    if (f != s_prog) {
        int x = (W - f->w * PROG_S) / 2;
        ui_fill(x, PROG_Y, f->w * PROG_S, f->h * PROG_S, UI_BG);
        ui_bitmap(f, x, PROG_Y, PROG_S, UI_INK);
        s_prog = f;
    }
    lc_header_tick(t_ms);
    if (right) lc_footer(NULL, 0, right);
}

void lc_stub(const lc_profile_t *p)
{
    ui_fill(0, 0, W, H, UI_BG);
    lc_header(p->title, 0);
    ui_bitmap(p->icon, W / 2 - 48, 110, 6, UI_INK);
    ui_bitmap(ui_anim_frame(&ui_anim_think, 600), W / 2 + 70, 140, 3, UI_T3);
    ui_text(&ui_font_mono24b, W / 2, 240, "Профиль в работе", UI_INK, UI_CENTER);
    ui_text(&ui_font_mono15, W / 2, 286, p->desc, UI_T3, UI_CENTER);
    static const lc_hint_t keys[] = {{"B", "назад"}};
    lc_footer(keys, 1, NULL);
}

void lc_error(const char *title, const char *what, const char *detail, uint32_t t_ms)
{
    ui_fill(0, 0, W, H, UI_BG);
    lc_header(title, t_ms);
    const ui_bitmap_t *f = ui_anim_frame(&ui_anim_error, t_ms);
    ui_bitmap(f, W / 2 - f->w * 2, 120, 4, UI_INK);
    ui_text(&ui_font_mono24b, W / 2, 240, what, UI_INK, UI_CENTER);
    char s[80];
    ui_ellipsize(&ui_font_mono15, detail, W - 64, s, sizeof s);
    ui_text(&ui_font_mono15, W / 2, 282, s, UI_T3, UI_CENTER);
    static const lc_hint_t keys[] = {{"B", "назад"}};
    lc_footer(keys, 1, NULL);
}
