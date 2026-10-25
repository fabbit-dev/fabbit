#include "la_screen.h"

#include <string.h>
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "fpga_link.h"
#include "la_capture.h"
#include "la_view.h"
#include "ui.h"

static lav_view_t view;
static lav_column_t columns[LAV_COLUMNS];
static la_status_t frozen;
static uint8_t *samples;
static bool have_snapshot, refresh;
static bool enable_pending;
static int64_t next_poll;

static bool same(const la_status_t *a, const la_status_t *b)
{
    return a->epoch == b->epoch && a->flags == b->flags && a->count == b->count &&
           a->trigger_index == b->trigger_index && a->base_hz == b->base_hz &&
           a->divider == b->divider && a->source == b->source && a->capacity == b->capacity;
}

static bool rect(int x, int y, int w, int h, const uint8_t *px, size_t stride)
{
    // UI uses 4-bit grayscale. Ordered threshold keeps text antialiasing readable in 1 bit.
    static uint8_t packed[FL_BUF_SIZE];
    int left = x & ~7, right = (x + w + 7) & ~7;
    int row = (right-left)/8;
    if (!row || !h) return true;
    fl_lock();
    fl_id_t id;
    uint32_t magic;
    esp_err_t e = fl_id(&id);
    if (e == ESP_OK && (strcmp(id.magic, "FBPR") || id.profile != LA_PROFILE_ID))
        e = ESP_ERR_NOT_FOUND;
    if (e == ESP_OK) e = fl_csr_read(64, &magic, 1);
    if (e == ESP_OK && magic != 0x46424d56) e = ESP_ERR_NOT_FOUND;
    for (int band = 0; band < h && e == ESP_OK;) {
        int rows = (FL_BUF_SIZE-4)/row;
        if (rows > h-band) rows = h-band;
        packed[0] = (right-left)>>8;
        packed[1] = right-left;
        packed[2] = rows>>8;
        packed[3] = rows;
        memset(packed+4, 0, (size_t)rows*row);
        for (int yy = 0; yy < rows; yy++) {
            const uint8_t *source = px + (size_t)(band+yy)*stride - (x-left)/2;
            for (int xx = left; xx < right; xx++) {
                uint8_t nibble = source[(xx-left)/2];
                nibble = (xx & 1) ? nibble & 15 : nibble >> 4;
                static const uint8_t threshold[4] = {1, 9, 13, 5};
                if (nibble > threshold[((y+band+yy)&1)*2+(xx&1)])
                    packed[4+yy*row+(xx-left)/8] |= 0x80u >> ((xx-left)&7);
            }
        }
        e = fl_write(0x44, ((uint32_t)(y+band)<<12)|(uint32_t)left,
                     packed, 4+(size_t)rows*row);
        band += rows;
    }
    fl_unlock();
    return e == ESP_OK;
}

static const ui_port_t ui_port = {.rect = rect};

static esp_err_t aggregate(void)
{
    uint32_t bytes = view.span * 2;
    for (uint32_t off = 0; off < bytes;) {
        uint32_t n = bytes-off < FL_BUF_SIZE ? bytes-off : FL_BUF_SIZE;
        la_status_t current;
        esp_err_t e = la_read(frozen.epoch, view.offset*2+off, samples+off, n, &current);
        if (e != ESP_OK) return e;
        if (!same(&current, &frozen)) return ESP_ERR_INVALID_STATE;
        off += n;
    }
    la_status_t final;
    esp_err_t e = la_status(&final);
    if (e != ESP_OK) return e;
    if (!same(&final, &frozen)) return ESP_ERR_INVALID_STATE;
    for (unsigned x = 0; x < LAV_COLUMNS; x++) {
        uint32_t begin, end;
        lav_range(&view, x, &begin, &end);
        lav_column(&columns[x], samples+(begin-view.offset)*2, end-begin);
    }
    return ESP_OK;
}

bool la_screen_attach(void)
{
    la_status_t status;
    if (la_status(&status) != ESP_OK) return false;
    uint32_t magic;
    fl_lock();
    esp_err_t e = fl_csr_read(64, &magic, 1);
    fl_unlock();
    if (e != ESP_OK || magic != 0x46424d56) return false;
    if (!samples) samples = heap_caps_malloc(LA_MAX_SAMPLES*2, MALLOC_CAP_SPIRAM);
    if (!samples) return false;
    uint8_t *fb = ui_fb();
    ui_init(fb, &ui_port);
    lav_init(&view);
    have_snapshot = false;
    refresh = true;
    enable_pending = false;  // First enable only after a complete framebuffer transfer succeeds.
    next_poll = 0;
    return true;
}

static void flush(void)
{
    if (ui_flush()) enable_pending = true;
    if (!enable_pending) return;
    fl_lock();
    fl_id_t id;
    if (fl_id(&id) == ESP_OK && !strcmp(id.magic, "FBPR") && id.profile == LA_PROFILE_ID &&
        fl_osd_show(true) == ESP_OK) enable_pending = false;
    fl_unlock();
}

bool la_screen_tick(void)
{
    int64_t now = esp_timer_get_time();
    if (!refresh && now < next_poll) { flush(); return true; }
    next_poll = now + 200000;
    la_status_t status;
    esp_err_t e = la_status(&status);
    if (e == ESP_ERR_NOT_FOUND) return false;
    if (e != ESP_OK) {
        if (view.state != LAV_ERROR) { view.state = LAV_ERROR; refresh = true; }
    } else if (status.flags & LA_DONE) {
        if (view.state != LAV_DONE) refresh = true;
        if (!have_snapshot || !same(&status, &frozen)) {
            frozen = status;
            have_snapshot = true;
            lav_capture(&view, status.count, status.trigger_index, status.base_hz, status.divider);
            refresh = true;
        }
        if (refresh) {
            view.state = LAV_DONE;
            if (aggregate() != ESP_OK) { view.state = LAV_ERROR; have_snapshot = false; }
        }
    } else {
        lav_state_t state = status.flags & LA_BUSY ? LAV_WAIT : LAV_READY;
        if (view.state != state) refresh = true;
        view.state = state;
        have_snapshot = false;
        view.count = 0;
        view.base_hz = status.base_hz;
        view.divider = status.divider;
    }
    if (refresh) {
        lav_draw(&view, columns);
        refresh = false;
    }
    flush();
    return true;
}

void la_screen_key(const in_event_t *event)
{
    if ((event->type != IN_PRESS && event->type != IN_REPEAT) ||
        (in_state() & (1u << IN_FN))) return;
    bool repeat = event->type == IN_REPEAT;
    switch (event->key) {
    case IN_UP: view.channel = (view.channel+15)%16; break;
    case IN_DOWN: view.channel = (view.channel+1)%16; break;
    case IN_LEFT: lav_pan(&view, false); break;
    case IN_RIGHT: lav_pan(&view, true); break;
    case IN_F1: if (!repeat) lav_zoom(&view, true); break;
    case IN_F4: if (!repeat) lav_zoom(&view, false); break;
    case IN_F3:
        if (!repeat) view.trigger = (view.trigger+1)%3;
        break;
    case IN_F2:
    case IN_MENU:
        if (!repeat) {
            la_status_t s;
            esp_err_t e = la_status(&s);
            if (e == ESP_OK && (s.flags & LA_BUSY)) e = la_abort();
            else if (e == ESP_OK) {
                la_config_t config = {.total = s.capacity, .post = s.capacity/2,
                    .divider = s.base_hz/10000000u-1u, .source = 0};
                if (view.trigger == LAV_RISE) config.rise = (uint16_t)(1u << view.channel);
                if (view.trigger == LAV_FALL) config.fall = (uint16_t)(1u << view.channel);
                e = la_arm(&config, &s);
            }
            if (e != ESP_OK) view.state = LAV_ERROR;
            have_snapshot = false;
        }
        break;
    default: return;
    }
    refresh = true;
}
