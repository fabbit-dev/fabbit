// Console transport for the capture profile. One @LA JSON line per command, including errors.
#include "cmd_capture.h"

#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_console.h"
#include "fpga_link.h"
#include "la_capture.h"

#define READ_MAX 1024

static bool number(const char *s, uint32_t *out)
{
    if (!s || !*s || *s == '-' || *s == '+') return false;
    char *end;
    errno = 0;
    unsigned long n = strtoul(s, &end, 0);
    if (errno || *end || n > UINT32_MAX) return false;
    *out = (uint32_t)n;
    return true;
}

static int failure(esp_err_t e)
{
    const char *code = "bus", *message = "Ошибка шины";
    if (e == ESP_ERR_NOT_FOUND) code = "profile", message = "В ПЛИС не профиль ЛА";
    else if (e == ESP_ERR_NOT_FINISHED) code = "pending", message = "Захват ещё не завершён";
    else if (e == ESP_ERR_INVALID_STATE)
        code = "changed", message = "Захват изменился во время чтения";
    else if (e == ESP_ERR_INVALID_ARG)
        code = "config", message = "Неверные параметры захвата";
    else if (e == ESP_ERR_INVALID_RESPONSE)
        code = "response", message = "Повреждённый ответ ПЛИС";
    else if (e == ESP_ERR_NO_MEM)
        code = "memory", message = "Недостаточно памяти";
    printf("@LA {\"ok\":false,\"error\":\"%s\",\"message\":\"%s\",\"detail\":%d}\n",
           code, message, (int)e);
    return 1;
}

static void print_status(const la_status_t *s)
{
    printf("@LA {\"ok\":true,\"op\":\"status\",\"flags\":%" PRIu32
           ",\"capacity\":%" PRIu32 ",\"base_hz\":%" PRIu32 ",\"count\":%" PRIu32
           ",\"trigger_index\":%" PRIu32 ",\"epoch\":%" PRIu32 ",\"divider\":%" PRIu32
           ",\"source\":%" PRIu32 "}\n", s->flags, s->capacity, s->base_hz, s->count,
           s->trigger_index, s->epoch, s->divider, s->source);
}

static int cmd_capture(int argc, char **argv)
{
    la_status_t status;
    esp_err_t e;
    if (argc == 2 && !strcmp(argv[1], "status")) {
        e = la_status(&status);
        if (e != ESP_OK) return failure(e);
        print_status(&status);
        return 0;
    }
    if (argc == 2 && !strcmp(argv[1], "abort")) {
        e = la_abort();
        if (e != ESP_OK) return failure(e);
        puts("@LA {\"ok\":true,\"op\":\"abort\"}");
        return 0;
    }
    if (argc >= 5 && argc <= 10 && !strcmp(argv[1], "arm")) {
        // total post divider [mask value rise fall source]; absent trigger masks mean immediate.
        uint32_t v[8] = {0};
        for (int i = 2; i < argc; i++) if (!number(argv[i], &v[i-2]))
            return failure(ESP_ERR_INVALID_ARG);
        for (int i = 3; i <= 6; i++) if (v[i] > UINT16_MAX)
            return failure(ESP_ERR_INVALID_ARG);
        la_config_t config = {.total = v[0], .post = v[1], .divider = v[2],
                              .mask = v[3], .value = v[4], .rise = v[5],
                              .fall = v[6], .source = v[7]};
        e = la_arm(&config, &status);
        if (e != ESP_OK) return failure(e);
        print_status(&status);
        return 0;
    }
    if (argc == 5 && !strcmp(argv[1], "read")) {
        uint32_t epoch, offset, n;
        if (!number(argv[2], &epoch) || !number(argv[3], &offset) ||
            !number(argv[4], &n) || !n || n > READ_MAX) return failure(ESP_ERR_INVALID_ARG);
        uint8_t *data = malloc(n);
        char *line = malloc(2*n + 192);
        if (!data || !line) { free(data); free(line); return failure(ESP_ERR_NO_MEM); }
        e = la_read(epoch, offset, data, n, &status);
        if (e != ESP_OK) { free(data); free(line); return failure(e); }
        int used = snprintf(line, 192, "@LA {\"ok\":true,\"op\":\"data\",\"epoch\":%" PRIu32
                            ",\"offset\":%" PRIu32 ",\"crc32\":\"%08" PRIx32 "\",\"hex\":\"",
                            status.epoch, offset, fl_crc32(0, data, n));
        static const char hex[] = "0123456789abcdef";
        for (uint32_t i = 0; i < n; i++) {
            line[used++] = hex[data[i] >> 4];
            line[used++] = hex[data[i] & 15];
        }
        strcpy(line + used, "\"}");
        // One stdio call limits interleaving with background log output. CRC catches corruption.
        puts(line);
        free(line);
        free(data);
        return 0;
    }
    return failure(ESP_ERR_INVALID_ARG);
}

void cmd_capture_register(void)
{
    const esp_console_cmd_t command = {
        .command = "capture",
        .help = "capture arm|status|read|abort: захват ЛА; arm total post divider [mask value rise fall source]",
        .func = cmd_capture,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&command));
}
