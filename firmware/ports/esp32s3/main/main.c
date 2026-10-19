// Fabbit loader: консоль для проверки шины и golden-образа ПЛИС.
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "driver/gpio.h"
#include "esp_console.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "fpga_link.h"
#include "profile_mgr.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static uint32_t arg_u32(const char *s) { return (uint32_t)strtoul(s, NULL, 0); }

static int cmd_id(int argc, char **argv)
{
    fl_id_t id;
    if (fl_id(&id) != ESP_OK) return 1;
    printf("ID magic=%s ver=%u mode=%u profile=%u\n", id.magic, id.version, id.mode, id.profile);
    return 0;
}

static int cmd_status(int argc, char **argv)
{
    fl_status_t st;
    if (fl_status(&st) != ESP_OK) return 1;
    char bs[96];
    fl_bootsts_str(st.bootsts, bs, sizeof bs);
    printf("STATUS busy=%u err=%u code=%u bootsts=%08" PRIx32 " (%s)\n", st.busy, st.error,
           st.err_code, st.bootsts, bs);
    return 0;
}

static int cmd_freq(int argc, char **argv)
{
    if (argc > 1 && fl_set_freq(arg_u32(argv[1]) * 1000000u) != ESP_OK) return 1;
    printf("FREQ %" PRIu32 " Hz\n", fl_get_freq());
    return 0;
}

// bench [раз]: случайные 8 КБ в буфер ПЛИС и обратно, ошибки и МБ/с
static int cmd_bench(int argc, char **argv)
{
    int rounds = argc > 1 ? atoi(argv[1]) : 50;
    uint8_t *w = heap_caps_malloc(FL_BUF_SIZE, MALLOC_CAP_INTERNAL);
    uint8_t *r = heap_caps_malloc(FL_BUF_SIZE, MALLOC_CAP_INTERNAL);
    if (!w || !r) return 1;
    uint32_t bad_bytes = 0, bad_rounds = 0;
    int64_t tw = 0, tr = 0;
    for (int i = 0; i < rounds; i++) {
        esp_fill_random(w, FL_BUF_SIZE);
        int64_t t0 = esp_timer_get_time();
        fl_buf_write(0, w, FL_BUF_SIZE);
        int64_t t1 = esp_timer_get_time();
        memset(r, 0, FL_BUF_SIZE);
        fl_buf_read(0, r, FL_BUF_SIZE);
        int64_t t2 = esp_timer_get_time();
        tw += t1 - t0;
        tr += t2 - t1;
        if ((i & 15) == 15) vTaskDelay(1);  // отдать процессор IDLE (task watchdog)
        uint32_t bad = 0;
        for (int k = 0; k < FL_BUF_SIZE; k++) bad += (w[k] != r[k]);
        if (bad) {
            if (!bad_rounds) {
                for (int k = 0; k < FL_BUF_SIZE; k++)
                    if (w[k] != r[k]) {
                        printf("  первая ошибка @%d: w=%02x r=%02x\n", k, w[k], r[k]);
                        break;
                    }
            }
            bad_rounds++;
            bad_bytes += bad;
        }
    }
    double mb = (double)rounds * FL_BUF_SIZE / (1024.0 * 1024.0);
    printf("BENCH f=%" PRIu32 " Hz rounds=%d bad_rounds=%" PRIu32 " bad_bytes=%" PRIu32
           " wr=%.2f MB/s rd=%.2f MB/s\n",
           fl_get_freq(), rounds, bad_rounds, bad_bytes, mb / (tw / 1e6), mb / (tr / 1e6));
    free(w);
    free(r);
    return bad_bytes ? 1 : 0;
}

static int cmd_flid(int argc, char **argv)
{
    uint32_t j;
    if (fl_flash_id(&j) != ESP_OK) return 1;
    printf("FLID %06" PRIx32 "\n", j & 0xFFFFFF);
    return 0;
}

static int cmd_erase(int argc, char **argv)
{
    if (argc < 2) return 1;
    esp_err_t e = fl_flash_erase64k(arg_u32(argv[1]));
    printf("ERASE %s\n", esp_err_to_name(e));
    return e != ESP_OK;
}

static int cmd_crc(int argc, char **argv)
{
    if (argc < 3) return 1;
    uint32_t c;
    int64_t t0 = esp_timer_get_time();
    if (fl_flash_crc(arg_u32(argv[1]), arg_u32(argv[2]), &c) != ESP_OK) return 1;
    printf("CRC %08" PRIx32 " (%lld ms)\n", c, (esp_timer_get_time() - t0) / 1000);
    return 0;
}

static int cmd_rd(int argc, char **argv)
{
    if (argc < 2) return 1;
    uint32_t a = arg_u32(argv[1]), n = argc > 2 ? arg_u32(argv[2]) : 64;
    if (n > 1024) n = 1024;
    uint8_t b[1024];
    if (fl_flash_read(a, b, n) != ESP_OK) return 1;
    for (uint32_t i = 0; i < n; i++)
        printf("%s%02x", (i % 16) ? " " : (i ? "\n" : ""), b[i]);
    printf("\n");
    return 0;
}

static void prog_cb(size_t done, size_t total)
{
    if (done == total || (done % (256 * 1024)) == 0) printf("  %u/%u\n", done, total);
}

// progtest <addr> [КБ]: записать случайные данные, сверить CRC ПЛИС с локальным
static int cmd_progtest(int argc, char **argv)
{
    if (argc < 2) return 1;
    uint32_t a = arg_u32(argv[1]);
    size_t n = (argc > 2 ? arg_u32(argv[2]) : 256) * 1024;
    uint8_t *d = heap_caps_malloc(n, MALLOC_CAP_SPIRAM);
    if (!d) return 1;
    esp_fill_random(d, n);
    int64_t t0 = esp_timer_get_time();
    esp_err_t e = fl_flash_write_image(a, d, n, prog_cb);
    int64_t t1 = esp_timer_get_time();
    uint32_t c = 0, local = fl_crc32(0, d, n);
    if (e == ESP_OK) e = fl_flash_crc(a, n, &c);
    printf("PROGTEST %s write=%lld ms crc fpga=%08" PRIx32 " local=%08" PRIx32 " %s\n",
           esp_err_to_name(e), (t1 - t0) / 1000, c, local, c == local ? "OK" : "MISMATCH");
    free(d);
    return !(e == ESP_OK && c == local);
}

static int cmd_boot(int argc, char **argv)
{
    if (argc < 2) return 1;
    return fl_boot(arg_u32(argv[1])) != ESP_OK;
}

static int cmd_wire(int argc, char **argv) { return fl_wiretest() != ESP_OK; }

static int cmd_pins(int argc, char **argv)
{
    static const char *names[] = {"SCK/12", "CS/10", "IO0/11", "IO1/13", "IO2/14", "IO3/9", "IRQ/5"};
    uint8_t pd, pu;
    if (fl_pins(&pd, &pu) != ESP_OK) return 1;
    for (int i = 0; i < 7; i++) {
        int a = pd >> i & 1, b = pu >> i & 1;
        printf("%-7s pd=%d pu=%d  %s\n", names[i], a, b,
               a && b ? "держится в 1 (3V3 или ПЛИС)" : !a && !b ? "держится в 0 (GND или ПЛИС)" : "свободна");
    }
    return 0;
}

static int cmd_iodump(int argc, char **argv)
{
    gpio_dump_io_configuration(stdout, (1ULL << 5) | (1ULL << 9) | (1ULL << 10) | (1ULL << 11) |
                                           (1ULL << 12) | (1ULL << 13) | (1ULL << 14));
    return 0;
}

// tune [МГц...]: перебор rd_start и фронта, проверка ID и 1 КБ буфера
static int cmd_tune(int argc, char **argv)
{
    static const int def_mhz[] = {1, 5, 10, 20, 26, 40};
    int n = argc > 1 ? argc - 1 : (int)(sizeof def_mhz / sizeof def_mhz[0]);
    uint8_t *w = heap_caps_malloc(1024, MALLOC_CAP_INTERNAL);
    uint8_t *r = heap_caps_malloc(1024, MALLOC_CAP_INTERNAL);
    if (!w || !r) return 1;
    uint32_t keep = fl_get_freq();
    for (int k = 0; k < n; k++) {
        int mhz = argc > 1 ? atoi(argv[k + 1]) : def_mhz[k];
        fl_set_freq(mhz * 1000000u);
        printf("%2d МГц (%" PRIu32 "):", mhz, fl_get_freq());
        for (int fall = 0; fall < 2; fall++)
            for (int st = 14; st <= 20; st++) {
                fl_tune(st, fall);
                fl_id_t id;
                bool ok = fl_id(&id) == ESP_OK && !memcmp(id.magic, "FBGL", 4);
                if (ok) {
                    esp_fill_random(w, 1024);
                    fl_buf_write(0, w, 1024);
                    fl_buf_read(0, r, 1024);
                    ok = !memcmp(w, r, 1024);
                }
                if (ok) printf(" %c%d", fall ? 'f' : 'r', st);
            }
        printf("\n");
    }
    fl_set_freq(keep);
    free(w);
    free(r);
    return 0;
}

static int cmd_settune(int argc, char **argv)
{
    if (argc < 3) return 1;
    return fl_tune(atoi(argv[1]), atoi(argv[2])) != ESP_OK;
}

static int cmd_bw(int argc, char **argv)
{
    if (argc < 3) return 1;
    uint8_t b[64];
    int n = 0;
    for (int i = 2; i < argc && n < 64; i++) b[n++] = (uint8_t)strtoul(argv[i], NULL, 16);
    return fl_buf_write(arg_u32(argv[1]), b, n) != ESP_OK;
}

static int cmd_br(int argc, char **argv)
{
    if (argc < 3) return 1;
    uint32_t n = arg_u32(argv[2]);
    if (n > 64) n = 64;
    uint8_t b[64];
    if (fl_buf_read(arg_u32(argv[1]), b, n) != ESP_OK) return 1;
    for (uint32_t i = 0; i < n; i++) printf("%02x ", b[i]);
    printf("\n");
    return 0;
}

static int cmd_la(int argc, char **argv)
{
    static const uint8_t key[4] = {'F', 'B', 'K', 'Y'};
    return fl_write(0x08, 0, key, 4) != ESP_OK;
}

// bwn <off> <n> [seed]: записать n байт шаблона (i*7+seed); brn <off> <n> [seed]: прочитать и сверить
static int cmd_bwn(int argc, char **argv)
{
    if (argc < 3) return 1;
    uint32_t off = arg_u32(argv[1]), n = arg_u32(argv[2]), sd = argc > 3 ? arg_u32(argv[3]) : 0;
    if (n > FL_BUF_SIZE) return 1;
    uint8_t *b = heap_caps_malloc(n, MALLOC_CAP_INTERNAL);
    for (uint32_t i = 0; i < n; i++) b[i] = (uint8_t)(i * 7 + sd);
    esp_err_t e = fl_buf_write(off, b, n);
    free(b);
    return e != ESP_OK;
}

static int cmd_brn(int argc, char **argv)
{
    if (argc < 3) return 1;
    uint32_t off = arg_u32(argv[1]), n = arg_u32(argv[2]), sd = argc > 3 ? arg_u32(argv[3]) : 0;
    if (n > FL_BUF_SIZE) return 1;
    uint8_t *b = heap_caps_malloc(n, MALLOC_CAP_INTERNAL);
    if (fl_buf_read(off, b, n) != ESP_OK) return 1;
    uint32_t bad = 0, first = n;
    for (uint32_t i = 0; i < n; i++)
        if (b[i] != (uint8_t)(i * 7 + sd)) {
            if (first == n) first = i;
            bad++;
        }
    printf("BRN n=%" PRIu32 " bad=%" PRIu32, n, bad);
    if (bad) printf(" first=%" PRIu32 " got=%02x want=%02x", first, b[first], (uint8_t)(first * 7 + sd));
    printf("\n");
    free(b);
    return bad != 0;
}

static int cmd_flsr(int argc, char **argv)
{
    uint8_t sr, cr;
    if (fl_flash_sr(&sr, &cr) != ESP_OK) return 1;
    printf("FLSR SR=%02x (BP=%u SRWD=%u) CR=%02x (TB=%u)\n", sr, (sr >> 2) & 0xF, sr >> 7, cr,
           (cr >> 3) & 1);
    return 0;
}

// flprot <bp>: BP3..0 (TB=1 считает снизу): 7 = нижние 4 МБ (golden), 0 = без защиты
static int cmd_flprot(int argc, char **argv)
{
    if (argc < 2) return 1;
    uint8_t sr, cr;
    if (fl_flash_sr(&sr, &cr) != ESP_OK) return 1;
    esp_err_t e = fl_flash_wrsr((uint8_t)((arg_u32(argv[1]) & 0xF) << 2), cr);
    printf("FLPROT %s\n", esp_err_to_name(e));
    return cmd_flsr(0, NULL) || e != ESP_OK;
}

static int cmd_ls(int argc, char **argv)
{
    pm_list();
    return 0;
}

static int cmd_slots(int argc, char **argv) { return pm_slots() != ESP_OK; }

// load <файл> [force]: загрузить профиль (force: переписать слот, даже если есть в кэше)
static int cmd_load(int argc, char **argv)
{
    if (argc < 2) return 1;
    return pm_load(argv[1], argc > 2 && !strcmp(argv[2], "force")) != ESP_OK;
}

static int cmd_wdt(int argc, char **argv)
{
    if (argc < 2) return 1;
    return fl_set_wdt(arg_u32(argv[1])) != ESP_OK;
}

// bootwait <addr>: BOOT и время до ответа ПЛИС (профиль или golden после отката), до 60 с
static int cmd_bootwait(int argc, char **argv)
{
    if (argc < 2) return 1;
    if (fl_boot(arg_u32(argv[1])) != ESP_OK) return 1;
    int64_t t0 = esp_timer_get_time();
    vTaskDelay(pdMS_TO_TICKS(5));
    while (esp_timer_get_time() - t0 < 60000000) {
        fl_id_t id;
        fl_tune(16, true);
        if (fl_id(&id) == ESP_OK && (!memcmp(id.magic, "FBGL", 4) || !memcmp(id.magic, "FBPR", 4))) {
            fl_status_t st = {0};
            // golden отвечает на ID сразу, а BOOTSTS читает через ~84 мс: ждём, пока освободится
            if (!memcmp(id.magic, "FBGL", 4)) {
                fl_wait_idle(1500);
                fl_status(&st);
            }
            char bs[96] = "";
            if (!memcmp(id.magic, "FBGL", 4)) fl_bootsts_str(st.bootsts, bs, sizeof bs);
            printf("BOOTWAIT %.4s через %lld мс, BOOTSTS %08" PRIx32 " %s\n", id.magic,
                   (esp_timer_get_time() - t0) / 1000, st.bootsts, bs);
            return 0;
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
    printf("BOOTWAIT нет ответа 60 с\n");
    return 1;
}

// icapdbg <reg>: прочитать регистр конфигурации через ICAP, показать 16 тактов выхода ICAP
static int cmd_icapdbg(int argc, char **argv)
{
    if (argc < 2) return 1;
    if (fl_write(0x0A, arg_u32(argv[1]) & 0x1F, NULL, 0) != ESP_OK) return 1;
    if (fl_wait_idle(100) != ESP_OK) return 1;
    uint8_t b[64];
    if (fl_read(0x0B, 0, b, 64) != ESP_OK) return 1;
    for (int i = 0; i < 16; i++)
        printf("%2d: %02x%02x%02x%02x\n", i, b[4 * i], b[4 * i + 1], b[4 * i + 2], b[4 * i + 3]);
    return 0;
}

static int cmd_golden(int argc, char **argv) { return fl_reboot_golden() != ESP_OK; }

static void reg(const char *name, const char *help, esp_console_cmd_func_t f)
{
    esp_console_cmd_t c = {.command = name, .help = help, .func = f};
    ESP_ERROR_CHECK(esp_console_cmd_register(&c));
}

void app_main(void)
{
    ESP_ERROR_CHECK(fl_init(10 * 1000 * 1000));
    if (pm_init() != ESP_OK) printf("хранилище профилей не смонтировано\n");
    esp_console_repl_t *repl = NULL;
    esp_console_repl_config_t rc = ESP_CONSOLE_REPL_CONFIG_DEFAULT();
    rc.prompt = "fabbit>";
    esp_console_dev_usb_serial_jtag_config_t uc = ESP_CONSOLE_DEV_USB_SERIAL_JTAG_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_console_new_repl_usb_serial_jtag(&uc, &rc, &repl));
    esp_console_register_help_command();
    reg("id", "ID ПЛИС (golden/профиль)", cmd_id);
    reg("status", "статус golden", cmd_status);
    reg("freq", "freq [МГц]: частота шины", cmd_freq);
    reg("bench", "bench [раз]: 8 КБ туда-обратно", cmd_bench);
    reg("flid", "JEDEC ID флеша ПЛИС", cmd_flid);
    reg("erase", "erase <addr>: стереть 64 КБ", cmd_erase);
    reg("crc", "crc <addr> <len>: CRC32 во флеше (считает ПЛИС)", cmd_crc);
    reg("rd", "rd <addr> [n]: прочитать флеш", cmd_rd);
    reg("progtest", "progtest <addr> [КБ]: запись случайных данных и сверка CRC", cmd_progtest);
    reg("boot", "boot <addr>: IPROG на адрес", cmd_boot);
    reg("wire", "прозвонка линий шины (для spikes/wiretest)", cmd_wire);
    reg("pins", "уровни линий шины со своей подтяжкой", cmd_pins);
    reg("iodump", "конфигурация пинов шины (IO_MUX/матрица)", cmd_iodump);
    reg("tune", "tune [МГц..]: перебор момента выдачи данных ПЛИС", cmd_tune);
    reg("settune", "settune <rd_start> <fall>", cmd_settune);
    reg("bw", "bw <off> <hex...>: записать в буфер ПЛИС", cmd_bw);
    reg("br", "br <off> <n>: прочитать буфер ПЛИС", cmd_br);
    reg("la", "взвести анализатор ПЛИС на следующий кадр", cmd_la);
    reg("bwn", "bwn <off> <n> [seed]: записать шаблон в буфер", cmd_bwn);
    reg("brn", "brn <off> <n> [seed]: прочитать и сверить шаблон", cmd_brn);
    reg("flsr", "регистры статуса/конфигурации флеша ПЛИС", cmd_flsr);
    reg("flprot", "flprot <bp>: защита снизу, 7 = 4 МБ golden", cmd_flprot);
    reg("ls", "профили в хранилище", cmd_ls);
    reg("slots", "таблица слотов во флеше ПЛИС", cmd_slots);
    reg("load", "load <файл> [force]: загрузить профиль", cmd_load);
    reg("wdt", "wdt <единицы>: TIMER для BOOT (x64 отсчётов), 0 = выкл", cmd_wdt);
    reg("bootwait", "bootwait <addr>: BOOT и время до ответа ПЛИС", cmd_bootwait);
    reg("icapdbg", "icapdbg <рег>: чтение через ICAP, 16 тактов выхода", cmd_icapdbg);
    reg("golden", "вернуться в golden из профиля", cmd_golden);
    printf("fabbit loader: шина %" PRIu32 " Hz\n", fl_get_freq());
    ESP_ERROR_CHECK(esp_console_start_repl(repl));
}
