// Экраны лаунчера поверх ui: шапка, подвал, профили, список игр, загрузка, заглушка, ошибка.
// Только рисование по готовым данным; состояние и ввод держит lc_app. Вид как у макетов
// (brand-kit, тёмная тема): выбранное инвертируется, клавиши в плашках.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "ui.h"

#define LC_THUMB_W 240  // превью игры: кадр NES без полей 8 пикселей по краям
#define LC_THUMB_H 224

typedef struct {
    const char *name, *title, *desc;  // title: заголовок экрана профиля, прописными
    char tag[24];  // метка справа: «NES · 2 игры», «скоро»
    const ui_bitmap_t *icon;
    bool ready;
} lc_profile_t;

#define LC_THUMB_BYTES (LC_THUMB_W / 2 * LC_THUMB_H)

typedef struct {
    char name[64];   // для списка: имя файла без расширения
    char path[96];   // файл ROM у порта
    uint8_t mapper;
    uint16_t prg_kb, chr_kb;
    uint32_t runs;
    const uint8_t *thumb;  // LC_THUMB_W×LC_THUMB_H, 4 бит, NULL: нет превью
} lc_game_t;

typedef struct {
    const char *key, *what;
} lc_hint_t;

// шапка: моргающий кролик, заголовок, значки справа. t_ms: время для анимации
void lc_header(const char *title, uint32_t t_ms);
// только кролик шапки, если сменился кадр; true: перерисован
bool lc_header_tick(uint32_t t_ms);
// кадр кролика шапки (сон: глаза закрыты)
void lc_header_mark(const ui_bitmap_t *f);
void lc_footer(const lc_hint_t *keys, int n, const char *right);
// заставка: логотип, как его рисует golden до OSD_CTRL (120, 182, клетка 5)
void lc_splash(void);

void lc_home(const lc_profile_t *p, int n, int sel);
// одна карточка: для смены выбора без перерисовки экрана
void lc_home_card(const lc_profile_t *all, int i, bool sel);
// смена выбора: две карточки и счётчик в подвале
void lc_home_sel(const lc_profile_t *p, int n, int old, int sel);

#define LC_LIST_ROWS 8
// top: первая видимая строка
void lc_games(const char *title, const lc_game_t *g, int n, int sel, int top);
// смена выбора: строки old и sel, превью и данные
void lc_games_sel(const lc_game_t *g, int n, int old, int sel, int top);

// загрузка: кролик бежит по полоске; перерисовывает только полоску
void lc_loading(const char *title, const char *game, const char *sub, uint32_t t_ms);
void lc_loading_tick(uint32_t t_ms, const char *right);
// строка этапа под названием игры
void lc_loading_stage(const char *sub);

void lc_stub(const lc_profile_t *p);
void lc_error(const char *title, const char *what, const char *detail, uint32_t t_ms);
