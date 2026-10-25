// Кнопки в игру: состояние 11 кнопок → слово RetroPad → команда PAD профиля (docs/bus-protocol.md).
// Fn — модификатор: пока Fn нажата, игра кнопок не видит, Fn + кнопка даёт горячую клавишу.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

// биты слова пада (раскладка как cont1_key Analogue Pocket)
enum {
    PAD_UP = 1 << 0, PAD_DOWN = 1 << 1, PAD_LEFT = 1 << 2, PAD_RIGHT = 1 << 3,
    PAD_A = 1 << 4,  // правая кнопка ромба
    PAD_B = 1 << 5,  // нижняя
    PAD_X = 1 << 6,  // верхняя
    PAD_Y = 1 << 7,  // левая
    PAD_L1 = 1 << 8, PAD_R1 = 1 << 9, PAD_L2 = 1 << 10, PAD_R2 = 1 << 11,
    PAD_L3 = 1 << 12, PAD_R3 = 1 << 13,
    PAD_SELECT = 1 << 14, PAD_START = 1 << 15,
};

typedef enum {
    PAD_HK_MENU,   // Fn нажата и отпущена одна: меню поверх игры (OSD, пока только событие)
    PAD_HK_RESET,  // Fn + Меню: сброс ядра
    PAD_HK_EXIT,   // Fn + Назад: выход в golden
} pad_hotkey_t;

typedef void (*pad_hotkey_cb_t)(pad_hotkey_t hk);

typedef struct {
    uint32_t sent;        // кадров PAD отправлено
    uint32_t skipped;     // смен состояния без профиля в ПЛИС (golden)
    uint32_t lat_max_us;  // наибольшее время от смены кнопок до конца кадра PAD
    uint32_t lat_last_us;
} pad_stats_t;

// задача кнопок: шлёт PAD при каждой смене и повтором раз в 100 мс, пока в ПЛИС профиль
esp_err_t pad_init(pad_hotkey_cb_t cb);
// false: не слать PAD (отладка через CSR профиля)
void pad_enable(bool on);
// слово пада сейчас (то, что видит игра)
uint16_t pad_word(void);
void pad_get_stats(pad_stats_t *st);
