// Real hotkey dispatch, mocks only profile/transport boundaries. No board access.
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "esp_err.h"
#define ESP_ERROR_CHECK(expr) assert((expr) == ESP_OK)
#include "../ports/esp32s3/main/cmd_pad.c"

static int locks, resets, stops, boots, legacy_writes;
static bool in_profile = true, retro = true, legacy;
static esp_err_t stop_result = ESP_OK;

void fl_lock(void) { locks++; }
void fl_unlock(void) { assert(locks > 0); locks--; }
esp_err_t fl_id(fl_id_t *id)
{
    assert(locks > 0);
    *id = (fl_id_t){0};
    strcpy(id->magic, in_profile ? "FBPR" : "FBGL");
    return ESP_OK;
}
bool retro_present(void) { assert(locks > 0); return retro; }
esp_err_t retro_reset(void) { assert(locks > 0); resets++; return ESP_OK; }
esp_err_t retro_stop(void) { assert(locks > 0); stops++; return stop_result; }
esp_err_t fl_reboot_golden(void)
{
    assert(locks > 0);
    assert(!retro || (stops > 0 && stop_result == ESP_OK));
    boots++;
    return ESP_OK;
}
esp_err_t fl_csr_read(uint8_t index, uint32_t *value, size_t count)
{
    assert(locks > 0 && index == NES_ID && count == 1);
    *value = legacy ? NES_MAGIC : 0;
    return ESP_OK;
}
esp_err_t fl_csr_write(uint8_t index, const uint32_t *value, size_t count)
{
    assert(locks > 0 && legacy && index == NES_CTRL && count == 1 && *value == (NES_KEY | 2));
    legacy_writes++;
    return ESP_OK;
}

int main(void)
{
    hotkey(PAD_HK_RESET);
    assert(resets == 1 && !stops && !boots && !legacy_writes && !locks);
    hotkey(PAD_HK_EXIT);
    assert(stops == 1 && boots == 1 && !locks);
    stop_result = ESP_ERR_TIMEOUT;
    hotkey(PAD_HK_EXIT);
    assert(stops == 2 && boots == 1 && !locks);  // never BOOT while drain is uncertain
    retro = false;
    legacy = true;
    hotkey(PAD_HK_RESET);
    assert(legacy_writes == 1 && resets == 1 && !locks);
    hotkey(PAD_HK_EXIT);
    assert(boots == 2 && stops == 2 && !locks);
    in_profile = false;
    hotkey(PAD_HK_RESET);
    hotkey(PAD_HK_EXIT);
    assert(legacy_writes == 1 && boots == 2 && stops == 2 && !locks);
    puts("ok RETRO hotkeys: reset, drain-before-exit, failed drain blocks BOOT, legacy NES");
    return 0;
}
