// Actual production RETRO transport + portable probe; only FPGA/time/filesystem boundaries mocked.
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "retro_rom.h"
#include "rom_file.h"
#include "fpga_link.h"

static char directory[512];
static bool no_memory;
static void *test_malloc(size_t n) { return no_memory ? NULL : malloc(n); }
static FILE *local_fopen(const char *path, const char *mode)
{
    char local[768];
    if (!strncmp(path, "/data/roms/", 11)) {
        int n = snprintf(local, sizeof local, "%s/%s", directory, path + 11);
        assert(n > 0 && (size_t)n < sizeof local);
        path = local;
    }
    return fopen(path, mode);
}
#define fopen local_fopen
#define malloc test_malloc
#include "../ports/esp32s3/components/retro_rom/retro_rom.c"
#undef malloc
#undef fopen

static struct {
    uint32_t st, rx, config[5], caps, assets;
    int locks, reads, writes, streams, begins, commits, aborts, progress;
    int busy, drain, ipl, coeff, fault;
    bool wrong_id;
    int64_t clock;
} m;
enum { FAIL_NONE, FAIL_STREAM, FAIL_FREE, FAIL_READY, FAIL_DONE, FAIL_RX, FAIL_STATUS,
       FAIL_READ, FAIL_BUSY, FAIL_WRITE, FAIL_ASSETS, FAIL_ACK, FAIL_ABORT_BUSY };
static uint8_t expected[65536];
static size_t expected_n;

void fl_lock(void) { m.locks++; }
void fl_unlock(void) { assert(m.locks > 0); m.locks--; }
int64_t esp_timer_get_time(void) { return m.clock += 1000; }
void vTaskDelay(TickType_t ticks) { m.clock += ticks * 1000; }
esp_err_t fl_id(fl_id_t *id)
{
    m.reads++;
    *id = (fl_id_t){.magic = "FBPR", .profile = m.wrong_id ? 1 : RETRO_PROFILE_ID};
    return ESP_OK;
}
esp_err_t fl_csr_read(uint8_t index, uint32_t *v, size_t n)
{
    assert(n == 1);
    m.reads++;
    if (m.fault == FAIL_READ && m.begins) { m.fault = FAIL_NONE; return ESP_FAIL; }
    switch (index) {
    case RETRO_ID: *v = RETRO_MAGIC; break;
    case RETRO_ABI: *v = 1; break;
    case RETRO_CAPS: *v = m.caps; break;
    case RETRO_ASSETS: *v = m.fault == FAIL_ASSETS ? 1 : m.assets; break;
    case RETRO_FREE: *v = m.fault == FAIL_FREE ? 4097 : 4096; break;
    case RETRO_RX: *v = m.rx + (m.fault == FAIL_RX ? 1 : 0); break;
    case RETRO_STAT:
        *v = m.st;
        if (m.busy) { *v |= RETRO_CMD_BUSY; m.busy--; }
        if (m.drain) { *v |= RETRO_DRAIN_BUSY; m.drain--; }
        if (m.fault == FAIL_BUSY && m.begins) *v |= RETRO_CMD_BUSY;
        if (m.fault == FAIL_ABORT_BUSY && m.aborts) *v |= RETRO_CMD_BUSY;
        if (m.fault == FAIL_READY) *v &= ~RETRO_READY;
        if (m.fault == FAIL_DONE) *v &= ~RETRO_PAYLOAD_DONE;
        if (m.fault == FAIL_STATUS && m.streams) *v |= RETRO_FAILED;
        break;
    default: assert(!"unexpected CSR read");
    }
    return ESP_OK;
}
esp_err_t fl_csr_write(uint8_t index, const uint32_t *v, size_t n)
{
    assert(m.locks > 0 && !m.busy);
    m.writes++;
    if (index == RETRO_SYSTEM) {
        assert(n == 5 && !m.drain && !m.st);
        memcpy(m.config, v, sizeof m.config);
        return ESP_OK;
    }
    assert(n == 1);
    if (m.fault == FAIL_WRITE && index == RETRO_CTRL && *v == (RETRO_KEY | RETRO_BEGIN)) return ESP_FAIL;
    m.busy = 2; // every command/asset write needs its own post-write polling
    if (index == RETRO_CTRL) {
        assert((*v & 0xffff0000) == RETRO_KEY);
        switch (*v & 0xffff) {
        case RETRO_ABORT:
            m.aborts++;
            m.st = 0;
            m.drain = 3;
            break;
        case RETRO_CLEAR_IPL:
            assert(!m.drain && !m.st);
            m.assets &= ~1u; m.ipl = 0;
            break;
        case RETRO_CLEAR_COEFF:
            assert(!m.drain && !m.st && m.ipl == 64 && (m.assets & 1));
            m.assets &= ~2u; m.coeff = 0;
            break;
        case RETRO_BEGIN:
            assert(!m.drain && m.config[0] >= 1 && m.config[0] <= 3);
            assert(m.config[1] == expected_n);
            if (m.config[0] == ROM_SNES) assert(m.assets == 3);
            m.rx = 0; m.begins++; m.st = RETRO_LOADING | RETRO_READY;
            // A lost/delayed acknowledgement outlasts BEGIN's deadline, but clears
            // during cleanup's separate pre-ABORT mailbox wait.
            if (m.fault == FAIL_ACK) m.busy = 1250;
            break;
        case RETRO_COMMIT:
            assert((m.st & RETRO_PAYLOAD_DONE) && m.rx == expected_n);
            m.commits++; m.st = RETRO_RUNNING;
            break;
        case RETRO_RESET: assert(m.st & RETRO_RUNNING); break;
        default: assert(!"unexpected command");
        }
    } else if (index == RETRO_IPL) {
        assert(!m.drain && !m.st && (*v >> 8) == (uint32_t)m.ipl);
        assert((*v & 255) == (uint32_t)m.ipl);
        if (++m.ipl == 64) m.assets |= 1;
    } else if (index == RETRO_COEFF) {
        assert(!m.drain && !m.st && (*v >> 12) == (uint32_t)m.coeff);
        assert((*v & 4095) == (uint32_t)m.coeff + 1);
        if (++m.coeff == 512) m.assets |= 2;
    } else assert(!"unexpected write");
    return ESP_OK;
}
esp_err_t fl_write(uint8_t cmd, uint32_t channel, const void *data, size_t n)
{
    assert(m.locks > 0 && !m.busy && !m.drain);
    assert(cmd == FL_CMD_STREAM && channel == 0 && n && n <= 4096 - 16);
    assert((m.st & RETRO_READY) && m.rx + n <= expected_n);
    assert(!memcmp(expected + m.rx, data, n));
    m.streams++;
    if (m.fault == FAIL_STREAM && m.streams == 2) return ESP_FAIL;
    m.rx += (uint32_t)n;
    if (m.rx == expected_n) m.st |= RETRO_PAYLOAD_DONE;
    return ESP_OK;
}
static void progress_cb(void *ctx, int pct)
{
    assert(ctx == &m && m.locks > 0 && pct >= 0 && pct <= 100);
    m.progress++;
}
static void reset_mock(void)
{
    assert(!m.locks);
    memset(&m, 0, sizeof m);
    m.caps = 7;
}
static void write_file(const char *name, const void *data, size_t n)
{
    char path[768];
    snprintf(path, sizeof path, "%s/%s", directory, name);
    FILE *f = fopen(path, "wb");
    assert(f && fwrite(data, 1, n, f) == n && !fclose(f));
}
static void be32_test(uint8_t *p, uint32_t v)
{ p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
static void fixture_md(void)
{
    memset(expected, 0, sizeof expected);
    memcpy(expected + 0x100, "SEGA MEGA DRIVE ", 16);
    be32_test(expected, 0xffff00); be32_test(expected + 4, 0x200);
    be32_test(expected + 0x1a4, 65535); expected[0x1f0] = 'U';
    expected_n = 65536;
    write_file("cart.gen", expected, expected_n);
}
static void fixture_snes(void)
{
    memset(expected, 0, sizeof expected);
    uint8_t *h = expected + 0x7fc0;
    h[0x15] = 0x30; h[0x17] = 6; h[0x19] = 1;
    h[0x1c] = 0xcb; h[0x1d] = 0xed; h[0x1e] = 0x34; h[0x1f] = 0x12; h[0x3d] = 0x80;
    expected_n = 65536;
    uint8_t prefix[512] = {0};
    char path[768]; snprintf(path, sizeof path, "%s/cart.smc", directory);
    FILE *f = fopen(path, "wb");
    assert(f && fwrite(prefix, 1, sizeof prefix, f) == sizeof prefix);
    assert(fwrite(expected, 1, expected_n, f) == expected_n && !fclose(f));
}
static void assets(void)
{
    uint8_t ipl[64], coeff[1024];
    for (unsigned i = 0; i < 64; i++) ipl[i] = i;
    for (unsigned i = 0; i < 512; i++) { coeff[2*i] = (i+1) & 255; coeff[2*i+1] = (i+1) >> 8; }
    write_file("snes.ipl", ipl, sizeof ipl);
    write_file("snes.gauss", coeff, sizeof coeff);
}
static void remove_file(const char *name)
{
    char path[768]; snprintf(path, sizeof path, "%s/%s", directory, name); assert(!unlink(path));
}

static void test_command_acknowledgements(void)
{
    uint32_t ms, st;
    reset_mock(); m.fault = FAIL_ACK;
    assert(retro_load_file("/data/roms/cart.gen", progress_cb, &m, &ms) == ESP_ERR_TIMEOUT);
    assert(ms >= 2000 && ms < 4000 && m.clock < 4000000);
    assert(!m.locks && m.begins == 1 && m.aborts == 2);
    assert(!m.streams && !m.commits && !m.progress && !m.st && !m.busy && !m.drain);
    // Cleanup succeeded, not the load: a subsequent load needs no mock-state reset.
    m.fault = FAIL_NONE;
    assert(retro_load_file("/data/roms/cart.gen", NULL, NULL, &ms) == ESP_OK);
    assert(!m.locks && m.commits == 1 && m.st == RETRO_RUNNING);

    reset_mock(); m.fault = FAIL_BUSY;
    assert(retro_load_file("/data/roms/cart.gen", progress_cb, &m, &ms) == ESP_ERR_TIMEOUT);
    assert(ms >= 4000 && ms < 4100 && m.clock < 4100000);
    assert(!m.locks && m.begins == 1 && m.aborts == 1);
    assert(!m.streams && !m.commits && !m.progress && (m.st & RETRO_LOADING));
    assert(fl_csr_read(RETRO_STAT, &st, 1) == ESP_OK && (st & RETRO_CMD_BUSY));
    int writes = m.writes;
    int64_t start = m.clock;
    assert(retro_stop() == ESP_ERR_TIMEOUT);
    assert(m.clock - start >= COMMAND_US && m.clock - start < COMMAND_US + 100000);
    assert(!m.locks && m.writes == writes && m.aborts == 1);

    // Even if ABORT clears all run/load/drain bits, its own unacknowledged
    // command must prevent a successful drain result.
    reset_mock(); m.st = RETRO_RUNNING; m.fault = FAIL_ABORT_BUSY;
    start = m.clock;
    assert(retro_stop() == ESP_ERR_TIMEOUT);
    assert(m.clock - start >= COMMAND_US && m.clock - start < COMMAND_US + 100000);
    assert(!m.locks && m.aborts == 1 && m.writes == 1 && !m.st && !m.drain);
    assert(fl_csr_read(RETRO_STAT, &st, 1) == ESP_OK && (st & RETRO_CMD_BUSY));
    m.fault = FAIL_NONE;
    assert(retro_stop() == ESP_OK);
    assert(!m.locks && m.aborts == 2 && !m.st && !m.busy && !m.drain);
}

int main(void)
{
    const char *tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) tmp = "/tmp";
    int len = snprintf(directory, sizeof directory, "%s/retro-test-XXXXXX", tmp);
    assert(len > 0 && (size_t)len < sizeof directory);
    assert(mkdtemp(directory));
    rom_info_t info;
    fixture_snes();
    assert(retro_preflight("/data/roms/cart.smc", &info) == ESP_ERR_NOT_FOUND);
    assert(!m.reads && !m.writes);
    assets();
    assert(retro_preflight("/data/roms/cart.smc", &info) == ESP_OK);
    assert(info.system == ROM_SNES && info.payload_offset == 512 && info.fast_rom);
    reset_mock();
    uint32_t ms;
    assert(retro_load_file("/data/roms/cart.smc", progress_cb, &m, &ms) == ESP_OK);
    assert(!m.locks && ms && m.ipl == 64 && m.coeff == 512 && m.progress && m.commits == 1);
    assert(m.config[2] == 16 && m.config[3] == 65536);
    assert(retro_reset() == ESP_OK && !m.locks);
    reset_mock(); m.fault = FAIL_ASSETS;
    assert(retro_load_file("/data/roms/cart.smc", NULL, NULL, &ms) == ESP_ERR_TIMEOUT);
    assert(m.aborts == 2 && !m.locks && !m.st && !m.begins);
    reset_mock();
    assert(retro_load_file("/data/roms/cart.smc", NULL, NULL, &ms) == ESP_OK);
    // Hot switch SNES -> MD -> NES on the same live profile, with no BOOT API present.
    fixture_md();
    assert(retro_load_file("/data/roms/cart.gen", NULL, NULL, &ms) == ESP_OK);
    assert(m.commits == 2 && m.assets == 3 && m.config[0] == ROM_MD);
    memset(expected, 0, sizeof expected); memcpy(expected, "NES\x1a", 4); expected[4] = 1;
    expected_n = 16400;
    write_file("cart.nes", expected, expected_n + 7); // legacy iNES stream excludes trailing data
    assert(retro_load_file("/data/roms/cart.nes", NULL, NULL, &ms) == ESP_OK);
    assert(m.commits == 3 && m.config[0] == ROM_NES && m.rx == 16400);
    int before_stop = m.aborts;
    assert(retro_stop() == ESP_OK && m.aborts == before_stop + 1 && !m.st && !m.drain && !m.locks);
    m.wrong_id = true;
    int before_writes = m.writes;
    assert(retro_stop() == ESP_ERR_INVALID_STATE && m.writes == before_writes && !m.locks);
    m.wrong_id = false;
    fixture_md();
    test_command_acknowledgements();
    int failures[] = {FAIL_STREAM, FAIL_FREE, FAIL_READY, FAIL_DONE, FAIL_RX, FAIL_STATUS,
                      FAIL_READ, FAIL_BUSY, FAIL_WRITE};
    for (size_t i = 0; i < sizeof failures / sizeof *failures; i++) {
        reset_mock(); m.fault = failures[i];
        assert(retro_load_file("/data/roms/cart.gen", progress_cb, &m, &ms) != ESP_OK);
        assert(!m.locks && !m.commits && m.clock < 40000000);
        if (m.fault != FAIL_BUSY) assert(m.aborts == 2 && !m.st && !m.drain);
        m.fault = FAIL_NONE; m.busy = 0;
        assert(retro_load_file("/data/roms/cart.gen", NULL, NULL, &ms) == ESP_OK);
        assert(!m.locks && m.commits == 1 && m.st == RETRO_RUNNING);
    }
    reset_mock(); m.wrong_id = true;
    assert(retro_load_file("/data/roms/cart.gen", NULL, NULL, &ms) == ESP_ERR_INVALID_STATE);
    assert(!m.writes && !m.locks);
    reset_mock(); m.caps = 1;
    assert(retro_load_file("/data/roms/cart.gen", NULL, NULL, &ms) == ESP_ERR_NOT_SUPPORTED);
    assert(!m.writes && !m.locks);
    reset_mock(); no_memory = true;
    assert(retro_load_file("/data/roms/cart.gen", NULL, NULL, &ms) == ESP_ERR_NO_MEM);
    assert(!m.locks && m.aborts == 2 && !m.st && !m.drain && !m.begins);
    no_memory = false;
    reset_mock();
    uint8_t bad[1025] = {0};
    write_file("snes.gauss", bad, sizeof bad);
    assert(retro_load_file("/data/roms/cart.smc", NULL, NULL, &ms) == ESP_ERR_INVALID_SIZE);
    assert(!m.reads && !m.writes && !ms);
    bad[1] = 0xf0; write_file("snes.gauss", bad, 1024);
    assert(retro_preflight("/data/roms/cart.smc", &info) == ESP_ERR_INVALID_RESPONSE);
    memset(bad, 0, sizeof bad); write_file("snes.gauss", bad, 1024);
    assert(retro_preflight("/data/roms/cart.smc", &info) == ESP_ERR_INVALID_RESPONSE);
    assert(!m.reads && !m.writes);
    const char *files[] = {"cart.gen", "cart.smc", "cart.nes", "snes.ipl", "snes.gauss"};
    for (size_t i = 0; i < sizeof files / sizeof *files; i++) remove_file(files[i]);
    assert(!rmdir(directory));
    puts("ok RETRO actual ABI: assets/coverage, exact STREAM, hot systems, deadlines, late ACK/permanent busy, abort/drain recovery, locks");
    return 0;
}
