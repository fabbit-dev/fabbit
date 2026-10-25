// Ввод стенда: 11 кнопок как на приборе и энкодер с нажатием. Опрос 1 кГц, события в очередь.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

typedef enum {
    IN_UP, IN_DOWN, IN_LEFT, IN_RIGHT,  // крестовина
    IN_F1, IN_F2, IN_F3, IN_F4,
    IN_MENU, IN_BACK, IN_FN,
    IN_ENC,                             // нажатие энкодера
    IN_KEYS
} in_key_t;

typedef enum {
    IN_PRESS,    // нажатие: первые 2 мс низкого уровня
    IN_RELEASE,  // отпускание: 5 мс высокого уровня подряд
    IN_LONG,     // удержание 600 мс, один раз
    IN_REPEAT,   // крестовина: повтор каждые 100 мс после 400 мс удержания
    IN_ROTATE,   // поворот энкодера на delta щелчков (+ по часовой)
} in_type_t;

typedef struct {
    uint8_t type;   // in_type_t
    uint8_t key;    // in_key_t, для IN_ROTATE не важен
    int16_t delta;  // IN_ROTATE: щелчки
    uint32_t t_ms;  // время от старта
} in_event_t;

// настроить ножки и PCNT, запустить опрос 1 кГц
esp_err_t in_init(void);
// следующее событие; false, если за wait не пришло
bool in_get(in_event_t *e, TickType_t wait);
// выбросить накопленные события
void in_flush(void);
// нажатые сейчас кнопки: бит (1 << in_key_t)
uint32_t in_state(void);
// будить задачу t (xTaskNotifyGive) при каждой смене in_state()
void in_set_notify(TaskHandle_t t);
// время последней смены in_state(), мкс от старта
int64_t in_change_us(void);
// счётчик PCNT энкодера с начала работы (отсчёты фронтов A и B)
int in_encoder_count(void);
const char *in_key_name(in_key_t k);
const char *in_type_name(in_type_t t);
