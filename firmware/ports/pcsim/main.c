// pcsim: экраны лаунчера на ПК без железа. Плоскость ПЛИС моделируется массивом, в неё идут только
// изменённые области (как по шине). Каждый экран сверяется с кадром супервизора и пишется в PGM.
//   make -C firmware/ports/pcsim  ->  build/pcsim/*.pgm, отчёт: байт по шине на экран
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lc_view.h"
#include "ui.h"
#include "ui_bitmaps.h"

static uint8_t fb[UI_FB_SIZE], plane[UI_FB_SIZE];
static size_t bus_bytes;
static int errors;

static void put(int x, int y, uint8_t c)
{
    uint8_t *p = plane + y * UI_STRIDE + x / 2;
    *p = (x & 1) ? (*p & 0xF0) | c : (*p & 0x0F) | (c << 4);
}

static void port_rect(int x, int y, int w, int h, const uint8_t *px, size_t stride)
{
    if ((x | w) & 1 || x < 0 || y < 0 || x + w > UI_W || y + h > UI_H) {
        printf("FAIL rect вне экрана или нечётный: %d %d %d %d\n", x, y, w, h);
        errors++;
        return;
    }
    for (int j = 0; j < h; j++) memcpy(plane + (y + j) * UI_STRIDE + x / 2, px + j * stride, w / 2);
    bus_bytes += 4 + (size_t)w / 2 * h;
}

static void port_fill(int x, int y, int w, int h, uint8_t c)
{
    for (int j = y; j < y + h; j++)
        for (int i = x; i < x + w; i++) put(i, j, c);
    bus_bytes += 5;
}

static const ui_port_t port = {port_rect, port_fill};

static void save(const char *name)
{
    char path[256];
    snprintf(path, sizeof path, "%s/%s.pgm", getenv("OUT") ? getenv("OUT") : ".", name);
    FILE *f = fopen(path, "wb");
    fprintf(f, "P5\n%d %d\n255\n", UI_W, UI_H);
    for (int y = 0; y < UI_H; y++)
        for (int x = 0; x < UI_W; x++) {
            uint8_t v = plane[y * UI_STRIDE + x / 2];
            fputc(((x & 1) ? v & 15 : v >> 4) * 17, f);
        }
    fclose(f);
}

// изменённое ушло в плоскость, и плоскость совпала с кадром
static void shot(const char *name)
{
    bus_bytes = 0;
    size_t n = ui_flush();
    if (memcmp(fb, plane, sizeof fb)) {
        printf("FAIL %s: плоскость не совпала с кадром\n", name);
        errors++;
    } else printf("ok   %-14s шина %6zu Б (%5.1f мс при 4,3 МБ/с)\n", name, bus_bytes, bus_bytes / 4300.0);
    (void)n;
    save(name);
}

int main(void)
{
    ui_init(fb, &port);
    lc_profile_t prof[] = {
        {"Ретро-консоль", "РЕТРО-КОНСОЛЬ", "Схема приставки в ПЛИС, картинка по HDMI", "NES · 2 игры", &ui_icon_retro, true},
        {"Логический анализатор", "ЛОГИЧЕСКИЙ АНАЛИЗАТОР", "Цифровые каналы с гребёнки в sigrok", "скоро", &ui_icon_logic, false},
    };
    lc_home(prof, 2, 0);
    shot("home");
    lc_home_card(prof, 0, false);
    lc_home_card(prof, 1, true);
    shot("home-sel");

    static uint8_t thumb[LC_THUMB_W / 2 * LC_THUMB_H];
    for (int j = 0; j < LC_THUMB_H; j++)
        for (int i = 0; i < LC_THUMB_W / 2; i++) thumb[j * LC_THUMB_W / 2 + i] = (((i / 8) ^ (j / 16)) & 1) ? 0x99 : 0x33;
    lc_game_t g[12] = {
        {"Super Mario Bros. 3", 4, 256, 128, 12, thumb},
        {"nes15", 0, 16, 8, 3, NULL},
    };
    const char *more[] = {"Battle City", "Contra", "Duck Tales", "Mega Man 2", "Tetris",
                          "The Legend of Zelda", "Очень длинное имя файла с игрой, которое не влезает",
                          "Kirby's Adventure", "Metroid", "Punch-Out!!"};
    for (int i = 0; i < 10; i++) {
        snprintf(g[2 + i].name, sizeof g[2 + i].name, "%s", more[i]);
        g[2 + i].mapper = 1;
        g[2 + i].prg_kb = 128;
    }
    ui_dirty_all();
    lc_games("РЕТРО-КОНСОЛЬ · NES", g, 12, 0, 0);
    shot("games");
    lc_games_sel(g, 12, 0, 1, 0);
    shot("games-sel");
    lc_games("РЕТРО-КОНСОЛЬ · NES", g, 12, 8, 4);
    shot("games-scroll");
    lc_games("РЕТРО-КОНСОЛЬ · NES", g, 0, 0, 0);
    shot("games-empty");

    lc_loading("РЕТРО-КОНСОЛЬ · NES", "Super Mario Bros. 3", "ядро nes из слота 3 · ROM 384 КБ", 0);
    shot("loading");
    lc_loading_tick(70 * 20, "0,4 с");
    shot("loading-tick");
    lc_stub(&prof[1]);
    shot("stub");
    lc_error("РЕТРО-КОНСОЛЬ · NES", "Профиль не запустился", "ПЛИС вернулась в golden: BOOTSTS CRC_ERR, слот 3", 0);
    shot("error");

    // развёртка: плоскость доходит до кадра шагами
    lc_home(prof, 2, 1);
    for (int y = 0; y < UI_H; y += 40) ui_reveal(y, y + 40);
    ui_reveal(UI_H, UI_H);
    if (memcmp(fb, plane, sizeof fb)) {
        printf("FAIL развёртка: плоскость не совпала с кадром\n");
        errors++;
    } else printf("ok   развёртка 12 шагов\n");

    printf(errors ? "ОШИБОК %d\n" : "ВСЁ OK\n", errors);
    return errors != 0;
}
