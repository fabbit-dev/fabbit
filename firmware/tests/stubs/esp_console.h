#pragma once
#include "esp_err.h"

typedef int (*esp_console_cmd_func_t)(int argc, char **argv);
typedef struct {
    const char *command;
    const char *help;
    esp_console_cmd_func_t func;
} esp_console_cmd_t;

esp_err_t esp_console_cmd_register(const esp_console_cmd_t *cmd);
