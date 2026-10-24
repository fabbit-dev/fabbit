// Кнопки в игру. Поток: input (опрос 1 кГц) будит задачу → слово пада → PAD по шине ПЛИС.
// Задержка: нажатие ловится за 2 мс, кадр PAD ~30 мкс; ядро NES читает кнопки раз в кадр.
#include "pad.h"

#include <string.h>

#include "esp_check.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "fpga_link.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "input.h"

static const char *TAG = "pad";

#define REPEAT_MS 100  // повтор PAD: профиль, загруженный позже, получит кнопки сам
#define TASK_PRIO 20   // выше консоли: кнопки не ждут длинных команд

// физическая кнопка → бит пада (раскладка прибора: F1 верх, F2 право, F3 низ, F4 лево)
static const uint16_t MAP[IN_KEYS] = {
    [IN_UP] = PAD_UP, [IN_DOWN] = PAD_DOWN, [IN_LEFT] = PAD_LEFT, [IN_RIGHT] = PAD_RIGHT,
    [IN_F1] = PAD_X, [IN_F2] = PAD_A, [IN_F3] = PAD_B, [IN_F4] = PAD_Y,
    [IN_MENU] = PAD_START, [IN_BACK] = PAD_SELECT,
};

static pad_hotkey_cb_t s_cb;
static volatile bool s_on = true;
static volatile uint16_t s_word;
static pad_stats_t s_st;

static uint16_t map_keys(uint32_t keys)
{
    uint16_t w = 0;
    for (int k = 0; k < IN_KEYS; k++)
        if (keys >> k & 1) w |= MAP[k];
    return w;
}

// отправить слово, если в ПЛИС профиль: в golden команда 33 неизвестна и затёрла бы код ошибки
// флеш-операции. ID и PAD идут под одним замком, между ними чужой BOOT не встанет.
static bool send(uint16_t w)
{
    bool ok = false;
    fl_lock();
    fl_id_t id;
    if (fl_id(&id) == ESP_OK && !memcmp(id.magic, "FBPR", 4)) ok = fl_pad(w, 0) == ESP_OK;
    fl_unlock();
    return ok;
}

static void task(void *arg)
{
    uint32_t prev = 0;    // кнопки на прошлом шаге
    uint32_t masked = 0;  // кнопки, которые игра не видит до отпускания (были нажаты с Fn)
    bool fn_alone = false;
    uint16_t sent_w = 0;
    int64_t last_tx = 0;
    const uint32_t fn = 1u << IN_FN;
    for (;;) {
        ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(REPEAT_MS));
        uint32_t keys = in_state();
        int64_t t_change = in_change_us();
        uint32_t pressed = keys & ~prev;

        if (pressed & fn) fn_alone = true;
        if (keys & fn) {
            uint32_t other = pressed & ~fn;
            if (other) fn_alone = false;
            if (s_cb && (other & (1u << IN_MENU))) s_cb(PAD_HK_RESET);
            if (s_cb && (other & (1u << IN_BACK))) s_cb(PAD_HK_EXIT);
            masked |= keys & ~fn;  // всё, что нажато вместе с Fn, игре не отдаём
        } else if (prev & fn) {
            if (fn_alone && s_cb) s_cb(PAD_HK_MENU);
            fn_alone = false;
        }
        masked &= keys;  // отпущенная кнопка снова доступна игре
        prev = keys;

        uint16_t w = (keys & fn) ? 0 : map_keys(keys & ~masked);
        s_word = w;
        int64_t now = esp_timer_get_time();
        if (!s_on || (w == sent_w && now - last_tx < REPEAT_MS * 1000)) continue;
        if (send(w)) {
            bool changed = w != sent_w;
            sent_w = w;
            last_tx = now;
            s_st.sent++;
            if (changed) {
                uint32_t lat = (uint32_t)(esp_timer_get_time() - t_change);
                s_st.lat_last_us = lat;
                if (lat > s_st.lat_max_us) s_st.lat_max_us = lat;
            }
        } else {
            if (w != sent_w) s_st.skipped++;
            sent_w = w;
            last_tx = now;
        }
    }
}

esp_err_t pad_init(pad_hotkey_cb_t cb)
{
    s_cb = cb;
    TaskHandle_t h;
    if (xTaskCreatePinnedToCore(task, "pad", 4096, NULL, TASK_PRIO, &h, 1) != pdPASS)
        return ESP_ERR_NO_MEM;
    in_set_notify(h);
    ESP_LOGI(TAG, "кнопки → PAD, повтор %d мс", REPEAT_MS);
    return ESP_OK;
}

void pad_enable(bool on) { s_on = on; }

uint16_t pad_word(void) { return s_word; }

void pad_get_stats(pad_stats_t *st) { *st = s_st; }
