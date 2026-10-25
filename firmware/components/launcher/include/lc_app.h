// Лаунчер: автомат экранов поверх lc_view. Заставка → профили → игры → загрузка → игра → назад
// в список на ту же игру. Порт даёт время, список игр, превью, запуск и хранение состояния;
// автомат не знает ни шины, ни файлов. Один код для ESP32-S3, CH32H417 и pcsim.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "lc_view.h"
#include "ui.h"

#define LC_GAMES_MAX 128

typedef enum { LC_UP, LC_DOWN, LC_LEFT, LC_RIGHT, LC_OK, LC_BACK } lc_key_t;

typedef struct {
    uint8_t profile;  // выбранный профиль на главном экране
    char game[64];    // имя последней игры
    char identity[100]; // additive v2 state, old profile+game prefix unchanged
} lc_saved_t;

// этап загрузки: строка под названием игры; pct < 0, если доли нет. Звать, только пока в ПЛИС
// golden: после BOOT плоскости нет
typedef void (*lc_progress_cb)(void *ctx, const char *stage, int pct);

typedef struct {
    uint32_t (*now_ms)(void);
    void (*sleep_ms)(uint32_t ms);
    // плоскость: палитра и показ (false: заставка ПЛИС)
    void (*palette)(const uint32_t rgb[16]);
    void (*show)(bool on);
    // игры по алфавиту; runs порт ведёт сам
    int (*games)(lc_game_t *g, int max);
    // превью игры в out (LC_THUMB_BYTES); false: превью нет
    bool (*thumb)(const lc_game_t *g, uint8_t *out);
    // загрузить ядро и ROM. true: игра идёт, плоскости больше нет до возврата в golden.
    // false: err заполнен; ПЛИС могла перезагрузиться, плоскость тогда пуста
    bool (*run)(const lc_game_t *g, lc_progress_cb cb, void *ctx, char *err, size_t n);
    void (*load)(lc_saved_t *s);
    void (*save)(const lc_saved_t *s);
} lc_port_t;

// в ПЛИС golden с плоскостью: заставка с бегущим кроликом (кнопка пропускает), главный экран
void lc_app_start(const lc_port_t *port, uint8_t *fb, const ui_port_t *ui);
void lc_app_key(lc_key_t k, bool repeat);
// анимации и сон; звать каждые 10–30 мс. Возвращает мс до следующего нужного вызова
uint32_t lc_app_tick(void);
// игра идёт (ПЛИС в профиле)
bool lc_app_running(void);
// ПЛИС снова в golden (выход из игры или сбой): заставка → список игр на той же игре
void lc_app_back(void);
// при старте супервизора ПЛИС уже в профиле: ждать возврата, как после запуска игры
void lc_app_attach_running(void);
