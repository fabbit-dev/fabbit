#include "ui.h"

#include <string.h>

#define DIRTY_MAX 16

typedef struct {
    int x0, y0, x1, y1;  // полуоткрытый прямоугольник
} rect_t;

static uint8_t *s_fb;
static const ui_port_t *s_port;
static rect_t s_clip = {0, 0, UI_W, UI_H};
static rect_t s_dirty[DIRTY_MAX];
static int s_ndirty;

static inline int imin(int a, int b) { return a < b ? a : b; }
static inline int imax(int a, int b) { return a > b ? a : b; }

void ui_init(uint8_t *fb, const ui_port_t *port)
{
    s_fb = fb;
    s_port = port;
    memset(fb, 0, UI_FB_SIZE);
    ui_clip_reset();
    ui_dirty_all();
}

uint8_t *ui_fb(void) { return s_fb; }

void ui_palette(uint32_t rgb[16])
{
    for (int i = 0; i < 16; i++) rgb[i] = 0x111111u * i;
}

void ui_clip(int x, int y, int w, int h)
{
    s_clip = (rect_t){imax(x, 0), imax(y, 0), imin(x + w, UI_W), imin(y + h, UI_H)};
}

void ui_clip_reset(void) { s_clip = (rect_t){0, 0, UI_W, UI_H}; }

static inline void put(int x, int y, uint8_t c)
{
    uint8_t *p = s_fb + y * UI_STRIDE + (x >> 1);
    *p = (x & 1) ? (*p & 0xF0) | c : (*p & 0x0F) | (c << 4);
}

static inline uint8_t get(int x, int y)
{
    uint8_t v = s_fb[y * UI_STRIDE + (x >> 1)];
    return (x & 1) ? v & 0x0F : v >> 4;
}

static inline bool in_clip(int x, int y)
{
    return x >= s_clip.x0 && x < s_clip.x1 && y >= s_clip.y0 && y < s_clip.y1;
}

// ---------------- изменённые области ----------------

static int area(rect_t r) { return (r.x1 - r.x0) * (r.y1 - r.y0); }
static rect_t join(rect_t a, rect_t b)
{
    return (rect_t){imin(a.x0, b.x0), imin(a.y0, b.y0), imax(a.x1, b.x1), imax(a.y1, b.y1)};
}

void ui_dirty(int x, int y, int w, int h)
{
    rect_t r = {imax(x, s_clip.x0), imax(y, s_clip.y0), imin(x + w, s_clip.x1), imin(y + h, s_clip.y1)};
    if (r.x0 >= r.x1 || r.y0 >= r.y1) return;
    r.x0 &= ~1;
    r.x1 = (r.x1 + 1) & ~1;
    // слить с областью, если общая площадь почти не растёт: меньше кадров на шине
    for (int i = 0; i < s_ndirty; i++) {
        rect_t u = join(s_dirty[i], r);
        if (area(u) <= area(s_dirty[i]) + area(r) + 2048) {
            s_dirty[i] = u;
            return;
        }
    }
    if (s_ndirty < DIRTY_MAX) {
        s_dirty[s_ndirty++] = r;
        return;
    }
    // мест нет: слить с той, где прирост меньше
    int best = 0, cost = 1 << 30;
    for (int i = 0; i < s_ndirty; i++) {
        int c = area(join(s_dirty[i], r)) - area(s_dirty[i]);
        if (c < cost) cost = c, best = i;
    }
    s_dirty[best] = join(s_dirty[best], r);
}

void ui_dirty_all(void)
{
    s_dirty[0] = (rect_t){0, 0, UI_W, UI_H};
    s_ndirty = 1;
}

size_t ui_flush(void)
{
    size_t bytes = 0;
    int pending = 0;
    for (int i = 0; i < s_ndirty; i++) {
        rect_t r = s_dirty[i];
        if (s_port && s_port->rect &&
            s_port->rect(r.x0, r.y0, r.x1 - r.x0, r.y1 - r.y0, s_fb + r.y0 * UI_STRIDE + r.x0 / 2,
                         UI_STRIDE)) bytes += (size_t)(r.x1 - r.x0) / 2 * (r.y1 - r.y0);
        else s_dirty[pending++] = r;
    }
    s_ndirty = pending;
    return bytes;
}

#define REVEAL_LINE 3

bool ui_reveal(int y0, int y1)
{
    s_ndirty = 0;
    y0 = imax(y0, 0);
    y1 = imin(y1, UI_H);
    if (!s_port) return false;
    if (y1 > y0 && (!s_port->rect ||
        !s_port->rect(0, y0, UI_W, y1 - y0, s_fb + y0 * UI_STRIDE, UI_STRIDE))) return false;
    if (y1 < UI_H && (!s_port->fill ||
        !s_port->fill(0, y1, UI_W, imin(REVEAL_LINE, UI_H - y1), UI_INK))) return false;
    return true;
}

// ---------------- примитивы ----------------

void ui_fill(int x, int y, int w, int h, uint8_t c)
{
    int x0 = imax(x, s_clip.x0), y0 = imax(y, s_clip.y0);
    int x1 = imin(x + w, s_clip.x1), y1 = imin(y + h, s_clip.y1);
    if (x0 >= x1 || y0 >= y1) return;
    ui_dirty(x0, y0, x1 - x0, y1 - y0);
    for (int yy = y0; yy < y1; yy++) {
        int xx = x0;
        if (xx & 1) put(xx++, yy, c);
        int n = (x1 - xx) / 2;
        memset(s_fb + yy * UI_STRIDE + xx / 2, c * 0x11, n);
        xx += 2 * n;
        if (xx < x1) put(xx, yy, c);
    }
}

void ui_frame(int x, int y, int w, int h, int t, uint8_t c)
{
    ui_fill(x, y, w, t, c);
    ui_fill(x, y + h - t, w, t, c);
    ui_fill(x, y + t, t, h - 2 * t, c);
    ui_fill(x + w - t, y + t, t, h - 2 * t, c);
}

void ui_hline_dash(int x, int y, int w, int t, int on, int off, uint8_t c)
{
    for (int xx = x; xx < x + w; xx += on + off) ui_fill(xx, y, imin(on, x + w - xx), t, c);
}

void ui_bitmap(const ui_bitmap_t *b, int x, int y, int s, uint8_t c)
{
    int row = (b->w + 7) / 8;
    for (int j = 0; j < b->h; j++)
        for (int i = 0; i < b->w; i++)
            if (b->d[j * row + i / 8] & (0x80 >> (i % 8)))
                for (int dy = 0; dy < s; dy++)
                    for (int dx = 0; dx < s; dx++) {
                        int xx = x + i * s + dx, yy = y + j * s + dy;
                        if (in_clip(xx, yy)) put(xx, yy, c);
                    }
    ui_dirty(x, y, b->w * s, b->h * s);
}

const ui_bitmap_t *ui_anim_frame(const ui_anim_t *a, uint32_t t_ms)
{
    uint32_t t = t_ms % a->total_ms;
    for (int i = 0; i < a->n; i++) {
        if (t < a->ms[i]) return &a->f[i];
        t -= a->ms[i];
    }
    return &a->f[a->n - 1];
}

// ---------------- текст ----------------

static uint32_t utf8_next(const char **ps)
{
    const uint8_t *s = (const uint8_t *)*ps;
    uint32_t c = *s++;
    int n = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : c >= 0xC0 ? 1 : 0;
    if (n) c &= 0x3F >> n;
    while (n-- && (*s & 0xC0) == 0x80) c = c << 6 | (*s++ & 0x3F);
    *ps = (const char *)s;
    return c;
}

static const ui_glyph_t *glyph(const ui_font_t *f, uint32_t cp)
{
    int lo = 0, hi = f->n - 1;
    while (lo <= hi) {
        int m = (lo + hi) / 2;
        if (f->gl[m].cp == cp) return &f->gl[m];
        if (f->gl[m].cp < cp) lo = m + 1;
        else hi = m - 1;
    }
    return cp == '?' ? &f->gl[0] : glyph(f, '?');
}

int ui_text_width(const ui_font_t *f, const char *s)
{
    int w = 0;
    while (*s) w += glyph(f, utf8_next(&s))->adv;
    return w;
}

int ui_text(const ui_font_t *f, int x, int y, const char *s, uint8_t c, ui_align_t al)
{
    int w = ui_text_width(f, s);
    if (al == UI_CENTER) x -= w / 2;
    else if (al == UI_RIGHT) x -= w;
    int x0 = x;
    while (*s) {
        const ui_glyph_t *g = glyph(f, utf8_next(&s));
        const uint8_t *m = f->px + g->off;
        int row = (g->w + 1) / 2;
        for (int j = 0; j < g->h; j++)
            for (int i = 0; i < g->w; i++) {
                int a = (i & 1) ? m[j * row + i / 2] & 0x0F : m[j * row + i / 2] >> 4;
                int xx = x + g->ox + i, yy = y + g->oy + j;
                if (!a || !in_clip(xx, yy)) continue;
                int d = get(xx, yy);
                put(xx, yy, (uint8_t)(d + ((int)c - d) * a / 15));
            }
        x += g->adv;
    }
    ui_dirty(x0 - 2, y, w + 4, f->asc + f->desc);
    return w;
}

void ui_ellipsize(const ui_font_t *f, const char *s, int w, char *out, size_t n)
{
    if (!n) return;
    out[0] = 0;
    bool ellipsis = ui_text_width(f, s) > w;
    int ell = ellipsis ? glyph(f, 0x2026)->adv : 0, acc = 0;
    if (ellipsis && (n < 4 || ell > w)) return;
    size_t limit = n - 1 - (ellipsis ? 3 : 0);
    const char *p = s, *cut = s;
    while (*p) {
        const char *q = p;
        int adv = glyph(f, utf8_next(&q))->adv;
        if (acc + adv + ell > w || (size_t)(q - s) > limit) break;
        acc += adv;
        p = q;
        cut = p;
    }
    size_t k = (size_t)(cut - s);
    memcpy(out, s, k);
    if (ellipsis) memcpy(out + k, "\xE2\x80\xA6", 4);  // «…» и 0
    else out[k] = 0;
}
