#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
typedef int ledc_channel_t;
typedef int ledc_timer_t;
enum { LEDC_LOW_SPEED_MODE, LEDC_TIMER_8_BIT = 8, LEDC_USE_XTAL_CLK = 2, LEDC_CHANNEL_2 = 2 };
typedef struct {
    int speed_mode, duty_resolution, timer_num, freq_hz, clk_cfg;
    bool deconfigure;
} ledc_timer_config_t;
typedef struct {
    int gpio_num, speed_mode, channel, timer_sel;
    uint32_t duty;
    bool deconfigure;
} ledc_channel_config_t;
esp_err_t ledc_timer_config(const ledc_timer_config_t *config);
esp_err_t ledc_channel_config(const ledc_channel_config_t *config);
esp_err_t ledc_timer_pause(int mode, ledc_timer_t timer);
esp_err_t ledc_stop(int mode, ledc_channel_t channel, uint32_t idle);
esp_err_t ledc_set_duty(int mode, ledc_channel_t channel, uint32_t duty);
esp_err_t ledc_update_duty(int mode, ledc_channel_t channel);
