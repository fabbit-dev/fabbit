#pragma once
#include "esp_err.h"
#include <stdint.h>
#include <stdio.h>
enum { GPIO_MODE_INPUT, GPIO_MODE_OUTPUT, GPIO_FLOATING, GPIO_PULLDOWN_ONLY, GPIO_PULLUP_ONLY,
    GPIO_PULLDOWN_ENABLE = 1 };
typedef struct { uint64_t pin_bit_mask; int mode, pull_down_en; } gpio_config_t;
esp_err_t gpio_config(const gpio_config_t *config);
esp_err_t gpio_reset_pin(int pin);
esp_err_t gpio_set_direction(int pin, int mode);
esp_err_t gpio_set_pull_mode(int pin, int mode);
esp_err_t gpio_set_level(int pin, int value);
int gpio_get_level(int pin);
