#pragma once
#include "esp_err.h"

enum { ESP_ERR_NVS_NO_FREE_PAGES = 0x110d, ESP_ERR_NVS_NEW_VERSION_FOUND = 0x1110 };
esp_err_t nvs_flash_init(void);
esp_err_t nvs_flash_erase(void);
