// Консоль профилей: регистры (CSR), «глаз» SDRAM (diag/sdram_eye) и профиль NES.
#include "cmd_profile.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_console.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "fpga_link.h"
#include "nes_rom.h"
#include "rom_port.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

// sdram_eye: номера регистров (diag/sdram_eye.sv)
enum { EYE_ID = 0, EYE_CTRL = 1, EYE_STAT = 2, EYE_ERR = 3, EYE_FIRST = 4, EYE_FADDR = 5, EYE_PHASE = 6 };
#define EYE_PERIOD 784  // шагов сдвига на период такта SDRAM: 14 периодов VCO × 56
#define EYE_STEP_NS 0.01984  // шаг: период VCO 900 МГц / 56

// csr <индекс> [значение]: прочитать или записать регистр профиля
static int cmd_csr(int argc, char **argv)
{
    if (argc < 2) return 1;
    uint8_t idx = (uint8_t)strtoul(argv[1], NULL, 0);
    if (argc > 2 && fl_csr_set(idx, (uint32_t)strtoul(argv[2], NULL, 0)) != ESP_OK) return 1;
    uint32_t v;
    if (fl_csr_read(idx, &v, 1) != ESP_OK) return 1;
    printf("CSR[%u] = %08" PRIx32 " (%" PRIu32 ")\n", idx, v, v);
    return 0;
}

static bool eye_present(void)
{
    fl_id_t id;
    if (fl_id(&id) != ESP_OK || strcmp(id.magic, "FBPR")) {
        printf("нет профиля (ID %s)\n", id.magic);
        return false;
    }
    if (fl_csr_get(EYE_ID) != 0x53445245) {  // "SDRE"
        printf("загружен не sdram_eye\n");
        return false;
    }
    return true;
}

static int16_t eye_pos(void) { return (int16_t)(fl_csr_get(EYE_PHASE) & 0xFFFF); }

// сдвинуть фазу на n шагов и дождаться конца сдвига
static void eye_shift(int n)
{
    while (n) {
        int k = n > 30000 ? 30000 : n < -30000 ? -30000 : n;
        fl_csr_set(EYE_PHASE, (uint32_t)(uint16_t)(int16_t)k);
        n -= k;
    }
    int64_t end = esp_timer_get_time() + 2000000;
    while ((fl_csr_get(EYE_PHASE) >> 31) && esp_timer_get_time() < end) vTaskDelay(1);
}

// прогнать тестер ms миллисекунд; вернуть проходы и новые ошибки
static void eye_run(int ms, uint32_t *passes, uint32_t *errs)
{
    uint32_t e0 = fl_csr_get(EYE_ERR), p0 = fl_csr_get(EYE_STAT) >> 16;
    fl_csr_set(EYE_CTRL, 1);
    vTaskDelay(pdMS_TO_TICKS(ms));
    fl_csr_set(EYE_CTRL, 0);
    int64_t end = esp_timer_get_time() + 3000000;
    while (!(fl_csr_get(EYE_STAT) & 2) && esp_timer_get_time() < end) vTaskDelay(1);
    *errs = fl_csr_get(EYE_ERR) - e0;
    *passes = ((fl_csr_get(EYE_STAT) >> 16) - p0) & 0xFFFF;
}

// eye [шаг] [мс]: перебрать фазу на весь период, поставить середину самого широкого окна без ошибок
static int cmd_eye(int argc, char **argv)
{
    if (!eye_present()) return 1;
    int step = argc > 1 ? atoi(argv[1]) : 16;
    int ms = argc > 2 ? atoi(argv[2]) : 500;
    if (step < 1) step = 1;
    int n = (EYE_PERIOD + step - 1) / step;
    bool *ok = calloc(n, sizeof *ok);
    if (!ok) return 1;
    int16_t base = eye_pos();
    printf("фаза: шаг %d (%.0f пс), %d точек, %d мс на точку\n", step, step * EYE_STEP_NS * 1000, n, ms);
    for (int i = 0; i < n; i++) {
        if (i) eye_shift(step);
        uint32_t p, e;
        eye_run(ms, &p, &e);
        ok[i] = p > 0 && e == 0;
        printf("%5d %+7.2f нс  проходов %3" PRIu32 "  ошибок %8" PRIu32 "  %s\n", eye_pos(),
               (eye_pos() - base) * EYE_STEP_NS, p, e, ok[i] ? "ок" : "X");
    }
    // самое длинное окно по кругу
    int best = 0, best_at = -1;
    for (int i = 0; i < n; i++) {
        int len = 0;
        while (len < n && ok[(i + len) % n]) len++;
        if (len > best) {
            best = len;
            best_at = i;
        }
        if (len == n) break;
    }
    if (best_at < 0) {
        printf("EYE окна нет: ни одной фазы без ошибок\n");
        free(ok);
        return 1;
    }
    int mid = (best_at + best / 2) % n;
    int target = base + mid * step;
    eye_shift(target - eye_pos());
    printf("EYE окно %d точек (%.2f нс), середина %d шагов от начала; фаза %d\n", best,
           best * step * EYE_STEP_NS, mid * step, eye_pos());
    free(ok);
    return 0;
}

// soak [с]: гонять тестер на текущей фазе
static int cmd_soak(int argc, char **argv)
{
    if (!eye_present()) return 1;
    int sec = argc > 1 ? atoi(argv[1]) : 60;
    uint32_t p, e;
    eye_run(sec * 1000, &p, &e);
    uint32_t first = fl_csr_get(EYE_FIRST), faddr = fl_csr_get(EYE_FADDR);
    printf("SOAK %d с, фаза %d: проходов %" PRIu32 " (%" PRIu32 " МБ), ошибок %" PRIu32 "\n", sec,
           eye_pos(), p, p * 4, e);
    if (e)
        printf("  первая: слово %05" PRIx32 " прочитано %02" PRIx32 " ждали %02" PRIx32 "\n", faddr,
               first >> 24, (first >> 16) & 0xFF);
    return e != 0;
}

// rom <файл>: загрузить .nes (из /data/roms/, если путь не указан) в профиль NES
static int cmd_rom(int argc, char **argv)
{
    if (argc < 2) return 1;
    char path[160];
    if (strchr(argv[1], '/')) snprintf(path, sizeof path, "%s", argv[1]);
    else snprintf(path, sizeof path, "/data/roms/%s%s", argv[1], strchr(argv[1], '.') ? "" : ".nes");
    uint32_t ms = 0;
    rom_info_t info;
    esp_err_t e = rom_port_probe(path, &info);
    if (e == ESP_OK) {
        if (!nes_present()) {
            printf("в ПЛИС не профиль NES\n");
            return 1;
        }
        e = rom_port_load(path, NULL, NULL, &ms);
    }
    printf("ROM %s: %s, %" PRIu32 " мс\n", path, esp_err_to_name(e), ms);
    return e != ESP_OK;
}

// joy [биты]: кнопки NES для отладки (A B Select Start Вверх Вниз Влево Вправо = биты 0..7),
// складываются с кнопками стенда (PAD)
static int cmd_joy(int argc, char **argv)
{
    if (!nes_present()) {
        printf("в ПЛИС не профиль NES\n");
        return 1;
    }
    if (argc > 1) fl_csr_set(NES_JOY, NES_KEY | (strtoul(argv[1], NULL, 0) & 0xFF));
    uint32_t v = fl_csr_get(NES_JOY);
    printf("JOY %02" PRIx32 ", пад 0 %04" PRIx32 "\n", v & 0xFF, v >> 16);
    return 0;
}

static int cmd_nesreset(int argc, char **argv)
{
    if (!nes_present()) {
        printf("в ПЛИС не профиль NES\n");
        return 1;
    }
    return fl_csr_set(NES_CTRL, NES_KEY | 2) != ESP_OK;
}

static void reg(const char *name, const char *help, esp_console_cmd_func_t f)
{
    esp_console_cmd_t c = {.command = name, .help = help, .func = f};
    ESP_ERROR_CHECK(esp_console_cmd_register(&c));
}

void cmd_profile_register(void)
{
    reg("csr", "csr <индекс> [значение]: регистр профиля", cmd_csr);
    reg("eye", "eye [шаг] [мс]: перебор фазы SDRAM (профиль sdram_eye), середина окна", cmd_eye);
    reg("soak", "soak [с]: тест SDRAM на текущей фазе (профиль sdram_eye)", cmd_soak);
    reg("rom", "rom <файл>: загрузить .nes в профиль NES (/data/roms/)", cmd_rom);
    reg("joy", "joy [биты]: кнопки джойстика 1 профиля NES", cmd_joy);
    reg("nesreset", "сброс ядра NES", cmd_nesreset);
}
