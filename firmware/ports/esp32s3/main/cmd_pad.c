// Консоль ввода стенда (кнопки, слово пада) и горячие клавиши Fn.
#include "cmd_pad.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_console.h"
#include "esp_timer.h"
#include "fpga_link.h"
#include "input.h"
#include "nes_rom.h"
#include "pad.h"


static void hotkey(pad_hotkey_t hk)
{
    switch (hk) {
    case PAD_HK_MENU:
        printf("[pad] Fn: меню (OSD ещё нет)\n");
        break;
    case PAD_HK_RESET:
        if (fl_csr_get(NES_ID) == NES_MAGIC) {
            fl_csr_set(NES_CTRL, NES_KEY | 2);
            printf("[pad] Fn+Меню: сброс NES\n");
        }
        break;
    case PAD_HK_EXIT:
        printf("[pad] Fn+Назад: выход в golden\n");
        fl_reboot_golden();
        break;
    }
}

static void print_word(uint16_t w)
{
    static const char *n[16] = {"Up", "Down", "Left", "Right", "A", "B", "X", "Y",
                                "L1", "R1", "L2", "R2", "L3", "R3", "Select", "Start"};
    printf("%04x", w);
    for (int i = 0; i < 16; i++)
        if (w >> i & 1) printf(" %s", n[i]);
}

// input [с]: события кнопок N секунд (по умолчанию 15)
static int cmd_input(int argc, char **argv)
{
    int sec = argc > 1 ? atoi(argv[1]) : 15;
    in_flush();
    printf("ввод %d с: жми кнопки\n", sec);
    int64_t end = esp_timer_get_time() + sec * 1000000LL;
    int events = 0;
    in_event_t e;
    while (esp_timer_get_time() < end) {
        if (!in_get(&e, pdMS_TO_TICKS(100))) continue;
        events++;
        if (e.type == IN_ROTATE) printf("%8" PRIu32 " мс  ROTATE %+d\n", e.t_ms, e.delta);
        else printf("%8" PRIu32 " мс  %-7s %s\n", e.t_ms, in_type_name(e.type), in_key_name(e.key));
    }
    printf("INPUT событий %d, нажато сейчас %03" PRIx32 "\n", events, in_state());
    return 0;
}

// pad [с|on|off]: слово пада при каждой смене N секунд и статистика; on/off: слать ли PAD
static int cmd_pad(int argc, char **argv)
{
    if (argc > 1 && (!strcmp(argv[1], "on") || !strcmp(argv[1], "off"))) {
        pad_enable(!strcmp(argv[1], "on"));
        return 0;
    }
    int sec = argc > 1 ? atoi(argv[1]) : 0;
    int64_t end = esp_timer_get_time() + sec * 1000000LL;
    uint16_t last = pad_word();
    while (esp_timer_get_time() < end) {
        uint16_t w = pad_word();
        if (w != last) {
            printf("%8lld мс  ", esp_timer_get_time() / 1000);
            print_word(w);
            printf("\n");
            last = w;
        }
        vTaskDelay(1);
    }
    pad_stats_t st;
    pad_get_stats(&st);
    printf("PAD ");
    print_word(pad_word());
    printf(" | кадров %" PRIu32 ", без профиля %" PRIu32 ", задержка последняя %" PRIu32
           " мкс, макс %" PRIu32 " мкс\n",
           st.sent, st.skipped, st.lat_last_us, st.lat_max_us);
    return 0;
}

static void reg(const char *name, const char *help, esp_console_cmd_func_t f)
{
    esp_console_cmd_t c = {.command = name, .help = help, .func = f};
    ESP_ERROR_CHECK(esp_console_cmd_register(&c));
}

void cmd_pad_register(void)
{
    ESP_ERROR_CHECK(in_init());
    ESP_ERROR_CHECK(pad_init(hotkey));
    reg("input", "input [с]: события кнопок", cmd_input);
    reg("pad", "pad [с|on|off]: слово пада и задержка; on/off: слать в профиль", cmd_pad);
}
