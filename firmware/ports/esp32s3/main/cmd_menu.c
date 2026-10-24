// Экраны лаунчера в плоскости golden с тестовыми данными: проверка ui и вывода по шине на стенде.
#include "cmd_menu.h"

#include <stdio.h>
#include <string.h>

#include "esp_console.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "fpga_link.h"
#include "lc_view.h"
#include "ui.h"
#include "ui_bitmaps.h"

static void port_rect(int x, int y, int w, int h, const uint8_t *px, size_t stride)
{
    fl_osd_rect(x, y, w, h, px, stride);
}

static void port_fill(int x, int y, int w, int h, uint8_t c) { fl_osd_fill(x, y, w, h, c * 0x11); }

static const ui_port_t s_port = {port_rect, port_fill};
static uint8_t *s_fb;

static const lc_profile_t PROF[] = {
    {"Ретро-консоль", "РЕТРО-КОНСОЛЬ", "Схема приставки в ПЛИС, картинка по HDMI", "NES · 2 игры",
     &ui_icon_retro, true},
    {"Логический анализатор", "ЛОГИЧЕСКИЙ АНАЛИЗАТОР", "Цифровые каналы с гребёнки в sigrok", "скоро",
     &ui_icon_logic, false},
};
static lc_game_t GAMES[] = {
    {"Super Mario Bros. 3", 4, 256, 128, 12, NULL},
    {"nes15", 0, 16, 8, 3, NULL},
};

static bool ensure(void)
{
    if (s_fb) return true;
    s_fb = heap_caps_malloc(UI_FB_SIZE, MALLOC_CAP_SPIRAM);
    if (!s_fb) return false;
    ui_init(s_fb, &s_port);
    uint32_t pal[16];
    ui_palette(pal);
    fl_osd_pal(0, pal, 16);
    return true;
}

// menu <home|sel|games|loading|stub|error|wipe>: нарисовать экран, время вывода по шине
static int cmd_menu(int argc, char **argv)
{
    const char *w = argc > 1 ? argv[1] : "home";
    if (!ensure()) return 1;
    int64_t t0 = esp_timer_get_time();
    bool wipe = false;
    if (!strcmp(w, "home")) lc_home(PROF, 2, 0);
    else if (!strcmp(w, "sel")) lc_home_card(PROF, 0, false), lc_home_card(PROF, 1, true);
    else if (!strcmp(w, "games")) lc_games("РЕТРО-КОНСОЛЬ · NES", GAMES, 2, 0, 0);
    else if (!strcmp(w, "loading")) lc_loading("РЕТРО-КОНСОЛЬ · NES", "Super Mario Bros. 3", "ядро nes из слота 3", 0);
    else if (!strcmp(w, "stub")) lc_stub(&PROF[1]);
    else if (!strcmp(w, "error")) lc_error("РЕТРО-КОНСОЛЬ · NES", "Профиль не запустился", "ПЛИС вернулась в golden", 0);
    else if (!strcmp(w, "wipe")) lc_home(PROF, 2, 1), wipe = true;
    else return 1;
    int64_t t1 = esp_timer_get_time();
    size_t n = 0;
    if (wipe) {
        for (int y = 0; y <= UI_H; y += 24) ui_reveal(y, y + 24 > UI_H ? UI_H : y + 24);
    } else n = ui_flush();
    int64_t t2 = esp_timer_get_time();
    fl_osd_show(true);
    printf("MENU %s: рисование %lld мс, шина %u Б за %lld мс\n", w, (t1 - t0) / 1000, (unsigned)n,
           (t2 - t1) / 1000);
    return 0;
}

void cmd_menu_register(void)
{
    esp_console_cmd_t c = {.command = "menu",
                           .help = "menu <home|sel|games|loading|stub|error|wipe>: экран лаунчера",
                           .func = cmd_menu};
    ESP_ERROR_CHECK(esp_console_cmd_register(&c));
}
