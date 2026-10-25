#pragma once
#include <stdbool.h>
#include "esp_err.h"
typedef struct { int max_files; bool format_if_mount_failed; } esp_vfs_fat_mount_config_t;
esp_err_t esp_vfs_fat_spiflash_mount_ro(const char *, const char *, const esp_vfs_fat_mount_config_t *);
