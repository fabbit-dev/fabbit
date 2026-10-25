#pragma once
#include "esp_err.h"
typedef int (*esp_console_cmd_func_t)(int argc, char **argv);
typedef struct {
    const char *command;
    const char *help;
    const char *hint;
    esp_console_cmd_func_t func;
    void *argtable;
} esp_console_cmd_t;
esp_err_t esp_console_cmd_register(const esp_console_cmd_t *command);
#define ESP_ERROR_CHECK(e) do { if ((e) != ESP_OK) abort(); } while (0)
