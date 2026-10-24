// Ввод стенда: кнопки на GND с внутренней подтяжкой, энкодер KY-040 на PCNT (x4, фильтр 1 мкс).
// Нажатие ловится за 2 мс (задержка в игре), дребезг гасится на отпускании (5 мс).
#include "input.h"

#include "driver/gpio.h"
#include "driver/pulse_cnt.h"
#include "esp_check.h"
#include "esp_timer.h"
#include "freertos/queue.h"

static const char *TAG = "input";

// ножки ESP32-S3, в комментариях контакт гребёнки J3 DevKitC-1; -1: кнопки нет
static const int8_t PIN[IN_KEYS] = {
    [IN_UP] = 47,     // J3-17, левая крестовина
    [IN_DOWN] = 45,   // J3-15, стрэп VDD_SPI: 0 при сбросе = 3,3 В, нажатие не мешает
    [IN_LEFT] = 21,   // J3-18
    [IN_RIGHT] = 48,  // J3-16; RGB-светодиод ревизии 1.0 платы, вход работает и с ним
    [IN_F1] = 2,      // J3-5, правая крестовина: верх
    [IN_F2] = 1,      // J3-4, право
    [IN_F3] = 41,     // J3-7, низ
    [IN_F4] = 42,     // J3-6, лево
    [IN_FN] = 38,     // J3-10, служебные слева направо; RGB-светодиод ревизии 1.1 платы
    [IN_MENU] = 39,   // J3-9
    [IN_BACK] = 40,   // J3-8
    [IN_ENC] = -1,    // энкодер пока не подключён
};
#define PIN_ENC_A -1  // CLK
#define PIN_ENC_B -1  // DT

#define PRESS_MS 2
#define RELEASE_MS 5
#define LONG_MS 600
#define REPEAT_DELAY_MS 400
#define REPEAT_MS 100
#define ENC_LIMIT 1000          // предел аппаратного счётчика, дальше PCNT накапливает сам
#define ENC_COUNTS_PER_STEP 4   // KY-040: щелчок = полный период квадратуры [НП, сверить на стенде]
#define ENC_DIR 1               // знак: по часовой = +

typedef struct {
    uint8_t cnt;  // мс подряд в противоположном уровне
    bool long_sent;
    uint32_t t0, next;
} key_st_t;

static key_st_t keys[IN_KEYS];
static volatile uint32_t state;
static volatile int64_t change_us;
static TaskHandle_t notify;
static QueueHandle_t queue;
static pcnt_unit_handle_t enc;
static int enc_last, enc_acc;

static void push(in_type_t t, int k, int delta, uint32_t now)
{
    in_event_t e = {.type = t, .key = k, .delta = delta, .t_ms = now};
    xQueueSend(queue, &e, 0);  // очередь полна: событие теряется, опрос не ждёт
}

static void poll(void *arg)
{
    uint32_t now = (uint32_t)(esp_timer_get_time() / 1000);
    uint32_t st = state;
    for (int k = 0; k < IN_KEYS; k++) {
        key_st_t *s = &keys[k];
        if (PIN[k] < 0) continue;
        bool low = !gpio_get_level(PIN[k]);
        if (!(st >> k & 1)) {
            s->cnt = low ? s->cnt + 1 : 0;
            if (s->cnt >= PRESS_MS) {
                st |= 1u << k;
                *s = (key_st_t){.t0 = now, .next = now + REPEAT_DELAY_MS};
                push(IN_PRESS, k, 0, now);
            }
            continue;
        }
        s->cnt = low ? 0 : s->cnt + 1;
        if (s->cnt >= RELEASE_MS) {
            st &= ~(1u << k);
            s->cnt = 0;
            push(IN_RELEASE, k, 0, now);
            continue;
        }
        if (!s->long_sent && now - s->t0 >= LONG_MS) {
            s->long_sent = true;
            push(IN_LONG, k, 0, now);
        }
        if (k <= IN_RIGHT && (int32_t)(now - s->next) >= 0) {
            s->next += REPEAT_MS;
            push(IN_REPEAT, k, 0, now);
        }
    }
    if (st != state) {
        change_us = esp_timer_get_time();
        state = st;
        if (notify) xTaskNotifyGive(notify);
    }

    if (!enc) return;
    int c = 0;
    pcnt_unit_get_count(enc, &c);
    enc_acc += c - enc_last;
    enc_last = c;
    int steps = enc_acc / ENC_COUNTS_PER_STEP;
    if (steps) {
        enc_acc -= steps * ENC_COUNTS_PER_STEP;
        push(IN_ROTATE, IN_ENC, ENC_DIR * steps, now);
    }
}

static esp_err_t enc_init(void)
{
    pcnt_unit_config_t uc = {.high_limit = ENC_LIMIT, .low_limit = -ENC_LIMIT, .flags.accum_count = 1};
    ESP_RETURN_ON_ERROR(pcnt_new_unit(&uc, &enc), TAG, "unit");
    pcnt_glitch_filter_config_t fc = {.max_glitch_ns = 1000};
    ESP_RETURN_ON_ERROR(pcnt_unit_set_glitch_filter(enc, &fc), TAG, "filter");
    // x4: каждый фронт A и B, направление по уровню другой линии (пример rotary_encoder ESP-IDF)
    pcnt_chan_config_t ca = {.edge_gpio_num = PIN_ENC_A, .level_gpio_num = PIN_ENC_B};
    pcnt_chan_config_t cb = {.edge_gpio_num = PIN_ENC_B, .level_gpio_num = PIN_ENC_A};
    pcnt_channel_handle_t a, b;
    ESP_RETURN_ON_ERROR(pcnt_new_channel(enc, &ca, &a), TAG, "chan A");
    ESP_RETURN_ON_ERROR(pcnt_new_channel(enc, &cb, &b), TAG, "chan B");
    pcnt_channel_set_edge_action(a, PCNT_CHANNEL_EDGE_ACTION_DECREASE, PCNT_CHANNEL_EDGE_ACTION_INCREASE);
    pcnt_channel_set_level_action(a, PCNT_CHANNEL_LEVEL_ACTION_KEEP, PCNT_CHANNEL_LEVEL_ACTION_INVERSE);
    pcnt_channel_set_edge_action(b, PCNT_CHANNEL_EDGE_ACTION_INCREASE, PCNT_CHANNEL_EDGE_ACTION_DECREASE);
    pcnt_channel_set_level_action(b, PCNT_CHANNEL_LEVEL_ACTION_KEEP, PCNT_CHANNEL_LEVEL_ACTION_INVERSE);
    // накопление за пределом работает через точки наблюдения на пределах
    ESP_RETURN_ON_ERROR(pcnt_unit_add_watch_point(enc, ENC_LIMIT), TAG, "wp+");
    ESP_RETURN_ON_ERROR(pcnt_unit_add_watch_point(enc, -ENC_LIMIT), TAG, "wp-");
    // у KY-040 подтяжки 10 кОм на модуле, у голого энкодера их нет
    gpio_pullup_en(PIN_ENC_A);
    gpio_pullup_en(PIN_ENC_B);
    ESP_RETURN_ON_ERROR(pcnt_unit_enable(enc), TAG, "enable");
    ESP_RETURN_ON_ERROR(pcnt_unit_clear_count(enc), TAG, "clear");
    return pcnt_unit_start(enc);
}

esp_err_t in_init(void)
{
    uint64_t mask = 0;
    for (int k = 0; k < IN_KEYS; k++)
        if (PIN[k] >= 0) mask |= 1ULL << PIN[k];
    gpio_config_t gc = {.pin_bit_mask = mask, .mode = GPIO_MODE_INPUT, .pull_up_en = GPIO_PULLUP_ENABLE};
    ESP_RETURN_ON_ERROR(gpio_config(&gc), TAG, "gpio");
    if (PIN_ENC_A >= 0) ESP_RETURN_ON_ERROR(enc_init(), TAG, "энкодер");
    queue = xQueueCreate(32, sizeof(in_event_t));
    if (!queue) return ESP_ERR_NO_MEM;
    esp_timer_handle_t t;
    esp_timer_create_args_t ta = {.callback = poll, .name = "input"};
    ESP_RETURN_ON_ERROR(esp_timer_create(&ta, &t), TAG, "timer");
    return esp_timer_start_periodic(t, 1000);
}

bool in_get(in_event_t *e, TickType_t wait) { return xQueueReceive(queue, e, wait) == pdTRUE; }

void in_flush(void) { xQueueReset(queue); }

uint32_t in_state(void) { return state; }

void in_set_notify(TaskHandle_t t) { notify = t; }

int64_t in_change_us(void) { return change_us; }

int in_encoder_count(void)
{
    int c = 0;
    if (enc) pcnt_unit_get_count(enc, &c);
    return c;
}

const char *in_key_name(in_key_t k)
{
    static const char *n[IN_KEYS] = {"UP", "DOWN", "LEFT", "RIGHT", "F1", "F2", "F3", "F4",
                                     "MENU", "BACK", "FN", "ENC"};
    return k < IN_KEYS ? n[k] : "?";
}

const char *in_type_name(in_type_t t)
{
    static const char *n[] = {"PRESS", "RELEASE", "LONG", "REPEAT", "ROTATE"};
    return t <= IN_ROTATE ? n[t] : "?";
}
