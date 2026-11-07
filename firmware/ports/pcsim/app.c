// Сценарий лаунчера на ПК: подставное время, кнопки, запуск игры (успех и сбой), возврат из игры.
#include <stdio.h>
#include <string.h>

#include "lc_app.h"
#include "pcsim.h"

static uint32_t s_ms;
static bool s_fail, s_shown;
static int s_runs, s_saves;
static lc_saved_t s_store;
static int s_count = 5;
static char s_last_game[64];
static char s_last_identity[100];
static bool s_same_titles;

static uint32_t now_ms(void) { return s_ms; }
static void sleep_ms(uint32_t ms) { s_ms += ms; }
static void palette(const uint32_t rgb[16]) {}
static void show(bool on) { s_shown = on; }

static int games(lc_game_t *g, int max)
{
    const char *n[] = {"Battle City", "Contra", "nes15", "Super Mario Bros. 3", "Tetris"};
    for (int i = 0; i < s_count && i < max; i++) {
        memset(&g[i], 0, sizeof g[i]);
        if (i < 5) snprintf(g[i].name, sizeof g[i].name, "%s", n[i]);
        else snprintf(g[i].name, sizeof g[i].name, "Game %03d", i);
        snprintf(g[i].path, sizeof g[i].path, "/roms/%s.nes", g[i].name);
        g[i].system = (uint8_t)(i % 3 + 1);
        snprintf(g[i].identity, sizeof g[i].identity, "%u:%s.nes", g[i].system, g[i].name);
        if (s_same_titles) snprintf(g[i].name, sizeof g[i].name, "Tetris");
        g[i].mapper = (uint8_t)i;
        g[i].prg_kb = 128;
    }
    return s_count;
}

static bool thumb(const lc_game_t *g, uint8_t *out)
{
    if (strcmp(g->name, "Super Mario Bros. 3")) return false;
    for (int j = 0; j < LC_THUMB_H; j++)
        for (int i = 0; i < LC_THUMB_W / 2; i++) out[j * LC_THUMB_W / 2 + i] = (uint8_t)(((i ^ j) & 8) ? 0xBB : 0x44);
    return true;
}

static bool run(const lc_game_t *g, lc_progress_cb cb, void *ctx, char *err, size_t n)
{
    cb(ctx, "проверка слотов", -1);
    s_ms += 300;
    cb(ctx, "запуск ядра", -1);
    s_ms += 340;
    s_runs++;
    snprintf(s_last_game, sizeof s_last_game, "%s", g->name);
    snprintf(s_last_identity, sizeof s_last_identity, "%s", g->identity);
    if (s_fail) {
        snprintf(err, n, "ядро NES не запустилось: ESP_FAIL");
        pcsim_plane_clear();  // ПЛИС откатилась в golden: плоскость пуста
        return false;
    }
    return true;
}

static void load(lc_saved_t *s) { *s = s_store; }
static void save(const lc_saved_t *s) { s_store = *s, s_saves++; }

static const lc_port_t port = {now_ms, sleep_ms, palette, show, games, thumb, run, load, save};

// крутить автомат t мс
static void spin(uint32_t t)
{
    uint32_t start = s_ms;
    while (s_ms - start < t) {
        uint32_t wait = lc_app_tick();
        s_ms += wait > 20 ? 20 : wait;
    }
}

static void key(lc_key_t k)
{
    lc_app_key(k, false);
    spin(300);
}

void pcsim_app(uint8_t *fb, const ui_port_t *ui)
{
    s_ms = 1000;
    lc_app_start(&port, fb, ui);
    pcsim_check(s_shown, "старт: плоскость включена (логотип совпадает с заставкой ПЛИС)");
    spin(400);
    pcsim_shot("app-intro");
    spin(1000);
    pcsim_shot("app-home");
    key(LC_DOWN);
    pcsim_shot("app-home-logic");
    key(LC_OK);
    pcsim_shot("app-stub");
    key(LC_BACK);
    key(LC_UP);
    key(LC_OK);
    pcsim_shot("app-games");
    key(LC_DOWN);
    key(LC_DOWN);
    key(LC_DOWN);
    pcsim_shot("app-games-smb3");
    key(LC_OK);
    pcsim_check(lc_app_running() && s_runs == 1 && s_saves == 1 && !strcmp(s_store.game, "Super Mario Bros. 3"),
                "A: игра запущена, выбор сохранён");
    pcsim_shot("app-loading");

    // выход из игры: golden снова, плоскость пуста
    pcsim_plane_clear();
    s_shown = false;
    lc_app_back();
    spin(400);
    pcsim_check(s_shown && !lc_app_running(), "возврат: плоскость снова показана");
    pcsim_shot("app-back");

    s_fail = true;
    key(LC_OK);
    pcsim_check(!lc_app_running() && s_runs == 2, "сбой запуска: остаёмся в меню");
    spin(300);
    pcsim_shot("app-error");
    key(LC_BACK);
    pcsim_shot("app-error-back");

    // включение после игры: курсор на последней игре
    s_fail = false;
    lc_app_start(&port, fb, ui);
    spin(1400);
    key(LC_OK);
    pcsim_shot("app-restart-games");

    // простой 2 мин: кролик закрывает глаза
    spin(121000);
    pcsim_shot("app-asleep");

    // Повторная инициализация после сна и повреждённого NVS, пустой каталог.
    memset(&s_store, 0xFF, sizeof s_store);
    s_count = 0;
    lc_app_start(&port, fb, ui);
    spin(1400);
    key(LC_OK);
    int before = s_runs;
    key(LC_OK);
    pcsim_check(s_runs == before && !lc_app_running(), "пустой каталог не запускает игру");
    pcsim_shot("app-empty");

    // Полный каталог, страницы, круговая прокрутка, переполнение миллисекунд.
    memset(&s_store, 0, sizeof s_store);
    s_count = LC_GAMES_MAX;
    s_ms = UINT32_MAX - 1000;
    lc_app_start(&port, fb, ui);
    spin(1400);
    key(LC_OK);
    key(LC_UP);
    key(LC_OK);
    pcsim_check(!strcmp(s_last_game, "Game 127"), "128 игр: вверх с первой выбирает последнюю");
    pcsim_plane_clear();
    lc_app_back();
    spin(400);
    pcsim_shot("app-full-back");
    key(LC_DOWN);
    key(LC_RIGHT);
    key(LC_OK);
    pcsim_check(!strcmp(s_last_game, "Game 008"), "страница: восемь строк после перехода по кругу");

    // Необязательные callbacks и ошибка перечисления.
    lc_port_t minimal = port;
    minimal.save = NULL;
    minimal.load = NULL;
    minimal.thumb = NULL;
    s_count = -1;
    lc_app_start(&minimal, fb, ui);
    spin(1400);
    key(LC_OK);
    pcsim_shot("app-list-error");
    s_count = 1;
    lc_app_start(&minimal, fb, ui);
    spin(1400);
    key(LC_OK);
    key(LC_OK);
    pcsim_check(lc_app_running(), "запуск без хранения состояния и превью");

    // Display titles may collide or change; restart selection uses system+path.
    s_count = 3;
    s_same_titles = true;
    memset(&s_store, 0, sizeof s_store);
    strcpy(s_store.game, "Tetris");
    strcpy(s_store.identity, "2:Contra.nes");
    lc_app_start(&port, fb, ui);
    spin(1400);
    key(LC_OK);
    key(LC_OK);
    pcsim_check(!strcmp(s_last_identity, "2:Contra.nes"), "identity: system+path, not duplicate display title");
    pcsim_check(!strcmp(s_store.identity, s_last_identity), "identity: saved on launch");
}
