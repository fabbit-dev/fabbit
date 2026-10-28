#include "la_view.h"

#include <stdio.h>
#include "lc_view.h"
#include "ui.h"

void lav_init(lav_view_t *v)
{
    *v = (lav_view_t){.state = LAV_READY, .base_hz = 400000000u, .span = LAV_COLUMNS};
}

void lav_capture(lav_view_t *v, uint32_t count, uint32_t trigger_index,
                 uint32_t base_hz, uint32_t divider)
{
    v->state = LAV_DONE;
    v->count = count;
    v->trigger_index = trigger_index;
    v->base_hz = base_hz;
    v->divider = divider;
    v->span = count < LAV_COLUMNS ? count : LAV_COLUMNS;
    v->offset = trigger_index > v->span / 2 ? trigger_index - v->span / 2 : 0;
    if (v->offset > count - v->span) v->offset = count - v->span;
}

void lav_zoom(lav_view_t *v, bool in)
{
    if (!v->count) return;
    uint32_t center = v->offset + v->span / 2;
    uint32_t span = in ? (v->span + 1) / 2 : v->span * 2;
    if (!span) span = 1;
    if (span > v->count) span = v->count;
    v->span = span;
    v->offset = center > span / 2 ? center - span / 2 : 0;
    if (v->offset > v->count - span) v->offset = v->count - span;
}

void lav_pan(lav_view_t *v, bool right)
{
    if (!v->count) return;
    uint32_t step = v->span / 4 ? v->span / 4 : 1;
    uint32_t limit = v->count - v->span;
    if (right) v->offset += step > limit - v->offset ? limit - v->offset : step;
    else v->offset -= step > v->offset ? v->offset : step;
}

void lav_range(const lav_view_t *v, unsigned column, uint32_t *begin, uint32_t *end)
{
    if (!v->count || !v->span || column >= LAV_COLUMNS) { *begin = *end = 0; return; }
    *begin = v->offset + (uint32_t)((uint64_t)column * v->span / LAV_COLUMNS);
    *end = v->offset + (uint32_t)((uint64_t)(column + 1) * v->span / LAV_COLUMNS);
    if (*end == *begin) (*end)++;
}

void lav_column(lav_column_t *out, const uint8_t *le16, size_t samples)
{
    *out = (lav_column_t){.low = UINT16_MAX};
    for (size_t i = 0; i < samples; i++) {
        uint16_t word = le16[2*i] | (uint16_t)le16[2*i+1] << 8;
        if (!i) out->first = word;
        out->last = word;
        out->low &= word;
        out->high |= word;
    }
}

void lav_draw(const lav_view_t *v, const lav_column_t columns[LAV_COLUMNS])
{
    static const char *states[] = {"Готов к захвату", "Ожидание триггера", "Захват готов", "Нет связи с ПЛИС"};
    static const char *triggers[] = {"*", "▲", "▼"};
    ui_fill(0, 0, UI_W, UI_H, UI_BG);
    lc_header("ЛОГИЧЕСКИЙ АНАЛИЗАТОР", 0);
    if (v->demo) {
        ui_fill(536, 8, 104, 36, UI_BG);
        ui_text(&ui_font_mono18b, 624, 15, "ДЕМО", UI_INK, UI_RIGHT);
    }
    ui_text(&ui_font_mono15b, 16, 60, states[v->state], UI_INK, UI_LEFT);
    char text[96];
    uint64_t divisor = (uint64_t)v->divider + 1;
    if (v->base_hz % divisor)
        snprintf(text, sizeof text, "%u/%llu МГц · номинальная", (unsigned)(v->base_hz/1000000u),
                 (unsigned long long)divisor);
    else if ((v->base_hz / divisor) % 1000000u == 0)
        snprintf(text, sizeof text, "%llu МГц · номинальная",
                 (unsigned long long)(v->base_hz / divisor / 1000000u));
    else
        snprintf(text, sizeof text, "%llu Гц · номинальная", (unsigned long long)(v->base_hz / divisor));
    ui_text(&ui_font_mono15, 624, 60, text, UI_T2, UI_RIGHT);
    snprintf(text, sizeof text, "Триггер D%u %s   ·   %u отсч.   ·   %u…%u",
             v->channel, triggers[v->trigger], (unsigned)v->count,
             (unsigned)v->offset, (unsigned)(v->offset + (v->count ? v->span : 0)));
    ui_text(&ui_font_mono15, 16, 83, text, UI_INK, UI_LEFT);
    for (unsigned channel = 0; channel < 16; channel++) {
        int y = 113 + (int)channel * 18;
        uint16_t mask = (uint16_t)(1u << channel);
        bool selected = channel == v->channel;
        if (selected) ui_fill(8, y-1, 56, 18, UI_INK);
        snprintf(text, sizeof text, "D%u", channel);
        ui_text(&ui_font_mono15b, 12, y, text, selected ? UI_BG : UI_INK, UI_LEFT);
        if (!columns || v->state != LAV_DONE) continue;
        for (unsigned x = 0; x < LAV_COLUMNS; x++) {
            const lav_column_t *c = &columns[x];
            bool changing = ((c->low ^ c->high) & mask) ||
                            (x && ((columns[x-1].last ^ c->first) & mask));
            int py = y + ((c->first & mask) ? 2 : 13);
            ui_fill(72+(int)x, changing ? y+2 : py, 1, changing ? 12 : 1, UI_INK);
        }
    }
    if (v->state == LAV_DONE && v->count && v->trigger_index >= v->offset &&
        v->trigger_index < v->offset + v->span) {
        int x = 72 + (int)((uint64_t)(v->trigger_index - v->offset) * LAV_COLUMNS / v->span);
        ui_fill(x, 106, 1, 3, UI_INK);
        ui_fill(x, 402, 1, 3, UI_INK);
    }
    ui_text(&ui_font_mono15, 16, 411, "▲▼ Канал   ◀▶ Сдвиг   X/Y Масштаб   B Триггер", UI_T2, UI_LEFT);
    const lc_hint_t hints[] = {{"A", v->state == LAV_WAIT ? "Стоп" : "Захват"}};
    lc_footer(hints, 1, "RAW / .sr: la_capture.py");
}
