#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "nes_rom.h"
#include "rom_port.h"

static int loads;
static esp_err_t result;
static const char *expected_path;
static void progress(void *ctx, int pct) { assert(ctx == &loads && pct == 100); }

esp_err_t nes_load_file(const char *path, void (*cb)(void *, int), void *ctx, uint32_t *ms)
{
    assert(!strcmp(path, expected_path) && cb == progress && ctx == &loads);
    loads++;
    if (ms) *ms = 17;
    cb(ctx, 100);
    return result;
}

static void fixture(const char *path, bool valid, size_t n)
{
    uint8_t h[16] = {'N', 'E', 'S', 0x1A, 1};
    if (!valid) memset(h, 0, sizeof h);
    FILE *f = fopen(path, "wb");
    assert(f && fwrite(h, 1, sizeof h, f) == sizeof h);
    assert(fseek(f, (long)n - 1, SEEK_SET) == 0 && fputc(0, f) == 0);
    assert(!fclose(f));
}

int main(void)
{
    const char *tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) tmp = "/tmp";
    char dir[256];
    int len = snprintf(dir, sizeof dir, "%s/fabbit-rom-XXXXXX", tmp);
    assert(len > 0 && (size_t)len < sizeof dir);
    assert(mkdtemp(dir));
    char path[512];
    const char *names[] = {"cart.md", "cart.GEN", "cart.sfc", "cart.SMC", "cart.bin", "bad.nes"};
    rom_info_t info;
    for (size_t i = 0; i < sizeof names / sizeof *names; i++) {
        snprintf(path, sizeof path, "%s/%s", dir, names[i]);
        fixture(path, false, 16400);
        uint32_t ms = 99;
        assert(rom_port_probe(path, &info) != ESP_OK);
        assert(!info.payload_size);
        assert(rom_port_load(path, progress, &loads, &ms) != ESP_OK && !loads && !ms);
        assert(!unlink(path));
    }
    snprintf(path, sizeof path, "%s/valid.bin", dir);
    fixture(path, true, 16407);
    assert(rom_port_probe(path, &info) == ESP_OK && info.payload_size == 16400);
    expected_path = path;
    result = ESP_OK;
    uint32_t ms;
    assert(rom_port_load(path, progress, &loads, &ms) == ESP_OK && loads == 1 && ms == 17);
    result = ESP_ERR_TIMEOUT;
    assert(rom_port_load(path, progress, &loads, &ms) == result && loads == 2);
    fixture(path, true, 16399);
    assert(rom_port_load(path, progress, &loads, &ms) == ESP_ERR_INVALID_SIZE && loads == 2 && !ms);
    assert(!unlink(path));
    assert(rom_port_probe(path, &info) == ESP_ERR_NOT_FOUND && !info.payload_size);
    assert(rom_port_load(path, progress, &loads, &ms) == ESP_ERR_NOT_FOUND && loads == 2);
    assert(rom_port_probe(NULL, &info) == ESP_ERR_INVALID_ARG);
    assert(rom_port_probe(path, NULL) == ESP_ERR_INVALID_ARG);
    assert(!rmdir(dir));
    puts("ok ROM port: preflight, NES-only dispatch, callbacks, error propagation, no hardware");
    return 0;
}
