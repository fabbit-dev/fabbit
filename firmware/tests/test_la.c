// Real LA client/console, fake link: descriptor tears, bus faults, epochs, bounds, command parser.
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_console.h"
#include "fpga_link.h"
#include "la_capture.h"
#include "cmd_capture.h"

// Allocation faults apply only to the production console translation unit.
static int fail_allocation, allocations;
void *test_capture_malloc(size_t size)
{
    return ++allocations == fail_allocation ? NULL : malloc(size);
}

enum { NORMAL, WRONG_PROFILE, ID_FAIL, CSR_FAIL, WRITE_FAIL, DATA_FAIL, EPOCH_CHANGE,
       DONE_TEAR, FOREVER_TEAR, MALFORMED, BAD_ARM, NO_DONE };
static int mode, locks, writes, reads, arms, status_reads;
static uint32_t regs[18];
static esp_console_cmd_func_t command;
static uint32_t last_offset;

static void reset(int m)
{
    assert(!locks);
    mode = m;
    writes = reads = arms = status_reads = 0;
    fail_allocation = allocations = 0;
    memset(regs, 0, sizeof regs);
    regs[0] = LA_MAGIC;
    regs[2] = LA_DONE | LA_TRIGGERED;
    regs[3] = LA_MAX_SAMPLES;
    regs[4] = 100000000;
    regs[12] = 2048;
    regs[13] = 1024;
    regs[14] = 7;
}
void fl_lock(void) { locks++; }
void fl_unlock(void) { assert(locks > 0); locks--; }
esp_err_t fl_id(fl_id_t *id)
{
    assert(locks > 0);
    if (mode == ID_FAIL) return ESP_ERR_TIMEOUT;
    *id = (fl_id_t){.profile = LA_PROFILE_ID, .mode = 1};
    strcpy(id->magic, mode == WRONG_PROFILE ? "FBGL" : "FBPR");
    return ESP_OK;
}
esp_err_t fl_csr_read(uint8_t index, uint32_t *v, size_t n)
{
    assert(locks > 0 && index + n <= 18);
    if (mode == CSR_FAIL) return ESP_ERR_TIMEOUT;
    if (mode == MALFORMED) regs[12] = UINT32_MAX;
    if (mode == NO_DONE) regs[2] = LA_BUSY, regs[12] = regs[13] = 0;
    memcpy(v, regs + index, n * sizeof *v);
    if (n == 18) {
        status_reads++;
        if (mode == DONE_TEAR && status_reads == 1) v[2] = LA_BUSY;
        if (mode == FOREVER_TEAR) v[14]++;
    }
    return ESP_OK;
}
esp_err_t fl_csr_write(uint8_t index, const uint32_t *v, size_t n)
{
    assert(locks > 0 && index + n <= 18);
    writes++;
    if (mode == WRITE_FAIL) return ESP_ERR_TIMEOUT;
    memcpy(regs + index, v, n * sizeof *v);
    if (index == 1 && *v == (LA_KEY | 1)) {
        arms++;
        regs[14]++;
        regs[2] = mode == BAD_ARM ? LA_BAD_CONFIG : (LA_DONE | LA_TRIGGERED);
        regs[12] = mode == BAD_ARM ? 0 : regs[5];
        regs[13] = mode == BAD_ARM ? 0 : regs[5] - regs[6];
        regs[15] = regs[7];
        regs[17] = regs[16];
    } else if (index == 1 && *v == (LA_KEY | 2)) regs[2] = regs[12] = regs[13] = 0;
    return ESP_OK;
}
esp_err_t fl_read(uint8_t cmd, uint32_t offset, void *data, size_t n)
{
    assert(locks > 0 && cmd == FL_CMD_CAPTURE_R && n <= FL_BUF_SIZE);
    reads++;
    last_offset = offset;
    // Incrementing 16-bit counter, little-endian, starting from sample 3976.
    for (size_t i = 0; i < n; i++) {
        uint32_t at = offset + (uint32_t)i;
        uint16_t sample = (uint16_t)(3976 + at/2);
        ((uint8_t *)data)[i] = (uint8_t)(sample >> ((at & 1) * 8));
    }
    if (mode == DATA_FAIL) return ESP_ERR_TIMEOUT;
    if (mode == EPOCH_CHANGE) regs[14]++;
    return ESP_OK;
}
uint32_t fl_crc32(uint32_t crc, const uint8_t *p, size_t n)
{
    crc = ~crc;
    while (n--) {
        crc ^= *p++;
        for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320u & -(crc & 1));
    }
    return ~crc;
}
esp_err_t esp_console_cmd_register(const esp_console_cmd_t *c)
{
    assert(!strcmp(c->command, "capture"));
    command = c->func;
    return ESP_OK;
}

static int run(const char *line)
{
    char buffer[256];
    assert(strlen(line) < sizeof buffer);
    strcpy(buffer, line);
    char *argv[16];
    int argc = 0;
    for (char *p = strtok(buffer, " "); p; p = strtok(NULL, " ")) argv[argc++] = p;
    int result = command(argc, argv);
    assert(!locks);
    return result;
}

int main(int argc, char **argv)
{
    cmd_capture_register();
    if (argc == 2 && !strcmp(argv[1], "--transcript")) {
        reset(NORMAL);
        assert(!run("capture status"));
        for (int offset = 0; offset < 4096; offset += 1024) {
            char line[80];
            snprintf(line, sizeof line, "capture read 7 %d 1024", offset);
            assert(!run(line));
        }
        assert(!run("capture status"));
        return 0;
    }
    la_status_t s;
    uint8_t data[1024];
    const int cases[] = {NORMAL, WRONG_PROFILE, ID_FAIL, CSR_FAIL, DATA_FAIL, EPOCH_CHANGE,
                         DONE_TEAR, FOREVER_TEAR, MALFORMED, NO_DONE};
    const esp_err_t expected[] = {ESP_OK, ESP_ERR_NOT_FOUND, ESP_ERR_TIMEOUT, ESP_ERR_TIMEOUT,
        ESP_ERR_TIMEOUT, ESP_ERR_INVALID_STATE, ESP_OK, ESP_ERR_INVALID_STATE,
        ESP_ERR_INVALID_RESPONSE, ESP_ERR_NOT_FINISHED};
    for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
        reset(cases[i]);
        memset(data, 0xA5, sizeof data);
        assert(la_read(7, 1023, data, sizeof data, &s) == expected[i] && !locks);
        if (expected[i] == ESP_OK) assert(reads == 1 && last_offset == 1023 && data[0] == 17);
        else for (size_t j = 0; j < sizeof data; j++) assert(data[j] == 0);
    }
    reset(NORMAL);
    assert(la_read(6, 0, data, 1, &s) == ESP_ERR_INVALID_STATE && !reads && !locks);
    assert(la_read(7, 4095, data, 2, &s) == ESP_ERR_INVALID_ARG && !reads && !locks);
    assert(la_read(7, UINT32_MAX, data, 2, &s) == ESP_ERR_INVALID_ARG && !reads && !locks);
    assert(la_read(7, 0, NULL, 1, &s) == ESP_ERR_INVALID_ARG);
    assert(la_status(NULL) == ESP_ERR_INVALID_ARG);
    la_config_t config = {.total = 32, .post = 16, .divider = 3, .source = 1};
    assert(la_arm(&config, &s) == ESP_OK && !locks && arms == 1 && s.count == 32 &&
           s.trigger_index == 16 && s.divider == 3 && s.source == 1);
    assert(la_abort() == ESP_OK && !locks && regs[2] == 0);
    reset(WRITE_FAIL);
    assert(la_arm(&config, &s) == ESP_ERR_TIMEOUT && !arms && !locks);
    reset(BAD_ARM);
    assert(la_arm(&config, &s) == ESP_ERR_INVALID_RESPONSE && !locks);
    reset(NORMAL);
    config.post = 0;
    assert(la_arm(&config, &s) == ESP_ERR_INVALID_ARG && !writes && !locks);
    config.post = 16;
    config.rise = config.fall = 1;
    assert(la_arm(&config, &s) == ESP_ERR_INVALID_ARG && !writes);
    config.rise = config.fall = 0;
    regs[14] = UINT32_MAX;
    assert(la_arm(&config, &s) == ESP_OK && s.epoch == 0 && !locks);
    reset(NORMAL);
    regs[3] = LA_MAX_SAMPLES - 2;
    regs[4] = 200000000;
    assert(la_status(&s) == ESP_OK && s.capacity == 131070 && s.base_hz == 200000000);
    config.total = LA_MAX_SAMPLES;
    assert(la_arm(&config, &s) == ESP_ERR_INVALID_ARG && !writes && !locks);
    config.total = 32;
    assert(la_arm(&config, &s) == ESP_OK && s.base_hz == 200000000 && !locks);
    puts("ok LA client: locks, faults, tears, epochs, bounds, ARM/ABORT, invalid descriptors");
    reset(NORMAL);
    assert(!run("capture arm 2048 1024 0 65535 5000 0 0 1"));
    assert(!run("capture read 8 1 31"));
    assert(!run("capture status"));
    for (int failure = 1; failure <= 2; failure++) {
        allocations = 0;
        fail_allocation = failure;
        int before = reads;
        assert(run("capture read 8 0 32") && reads == before);
    }
    fail_allocation = 0;
    const char *invalid[] = {"capture", "capture read -1 0 1", "capture read 8 0 1025",
        "capture read 8 0 0", "capture read 4294967296 0 1", "capture read 8 0 1x",
        "capture arm 1 1 0 65536", "capture arm 1 1 0 0 0 1 1", "capture arm 1 1 0 0 0 0 0 2",
        "capture arm 0 1 0", "capture status extra"};
    for (size_t i = 0; i < sizeof invalid / sizeof *invalid; i++) {
        int before = writes;
        assert(run(invalid[i]) && before == writes);
    }
    assert(!run("capture abort"));
    assert(run("capture read 8 0 1"));
    puts("ok LA console: arm/status/read/abort, parser, allocation faults, length/mask/source checks");
    return 0;
}
