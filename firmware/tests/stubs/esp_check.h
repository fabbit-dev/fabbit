#pragma once
#include "esp_err.h"
#define ESP_RETURN_ON_ERROR(expr, ...) do { esp_err_t e_ = (expr); if (e_ != ESP_OK) return e_; } while (0)
