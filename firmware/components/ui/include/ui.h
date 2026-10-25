// Графика меню: кадр 640×480 по 4 бита на пиксель в памяти супервизора, примитивы, шрифты
// JetBrains Mono со сглаживанием, битмапы brand-kit. Изменённые области копятся и уходят в плоскость
// ПЛИС через ui_flush (обратный вызов порта). Чистый C11, без ОС: тот же код на ESP32-S3, H417 и ПК.
//
// Палитра серая и линейная: индекс i = яркость 17·i (ui_palette). Поэтому сглаживание шрифта —
// это смешивание индексов, без таблиц. Цвета темы по токенам brand-kit, тёмная тема прибора.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define UI_W 640
#define UI_H 480
#define UI_STRIDE (UI_W / 2)
#define UI_FB_SIZE (UI_STRIDE * UI_H)

enum {
    UI_BG = 0,      // фон #000
    UI_LINE = 2,    // разделители, рамки (line #262626 тёмной темы)
    UI_MUTED = 5,   // неактивное, декор (muted #525252)
    UI_T3 = 10,     // подписи (text-3 #A3A3A3)
    UI_T2 = 13,     // вторичный текст (text-2 #D4D4D4)
    UI_INK = 15,    // основной текст, знак #FFF
};

typedef struct {
    uint16_t w, h;
    const uint8_t *d;  // 1 бит, строки по целому байту, старший бит левее
} ui_bitmap_t;

typedef struct {
    uint8_t n;
    uint16_t total_ms;
    const ui_bitmap_t *f;
    const uint16_t *ms;  // длительность каждого кадра
} ui_anim_t;

typedef struct {
    uint16_t cp;     // код Unicode
    uint8_t w, h;    // размер маски
    int8_t ox, oy;   // смещение маски от левого верхнего угла строки
    uint8_t adv;     // шаг
    uint32_t off;    // начало маски в px: 4 бит альфа, строки по целому байту
} ui_glyph_t;

typedef struct {
    uint8_t size, asc, desc;  // строка = asc + desc пикселей, базовая линия на asc
    uint16_t n;               // глифов, по возрастанию cp
    const ui_glyph_t *gl;
    const uint8_t *px;
} ui_font_t;

extern const ui_font_t ui_font_mono15, ui_font_mono15b, ui_font_mono18, ui_font_mono18b,
    ui_font_mono20b, ui_font_mono24b;

typedef enum { UI_LEFT, UI_CENTER, UI_RIGHT } ui_align_t;

// вывод в плоскость (порт): x, w чётные; px указывает на (x, y) кадра, stride в байтах;
// false: передача не завершена, повторить область целиком
typedef struct {
    bool (*rect)(int x, int y, int w, int h, const uint8_t *px, size_t stride);
    bool (*fill)(int x, int y, int w, int h, uint8_t c);  // прямо в плоскость, мимо кадра
} ui_port_t;

// fb: UI_FB_SIZE байт (на ESP в PSRAM)
void ui_init(uint8_t *fb, const ui_port_t *port);
uint8_t *ui_fb(void);
// палитра для плоскости: 16 цветов 0xRRGGBB
void ui_palette(uint32_t rgb[16]);

// область рисования; всё за ней отброшено
void ui_clip(int x, int y, int w, int h);
void ui_clip_reset(void);

void ui_fill(int x, int y, int w, int h, uint8_t c);
void ui_frame(int x, int y, int w, int h, int t, uint8_t c);  // рамка толщиной t внутрь
void ui_hline_dash(int x, int y, int w, int t, int on, int off, uint8_t c);
// 1-битный битмап в масштабе s: единицы цветом c, нули не трогает
void ui_bitmap(const ui_bitmap_t *b, int x, int y, int s, uint8_t c);
// кадр анимации на момент t_ms (по кругу)
const ui_bitmap_t *ui_anim_frame(const ui_anim_t *a, uint32_t t_ms);

// текст UTF-8; y = верх строки. Возвращает ширину. Неизвестный символ рисуется как «?»
int ui_text(const ui_font_t *f, int x, int y, const char *s, uint8_t c, ui_align_t al);
int ui_text_width(const ui_font_t *f, const char *s);
// обрезать строку до ширины w с «…» в конце; out не меньше n байт
void ui_ellipsize(const ui_font_t *f, const char *s, int w, char *out, size_t n);

// пометить область изменённой (примитивы делают это сами)
void ui_dirty(int x, int y, int w, int h);
void ui_dirty_all(void);
// отправить изменённые области в плоскость; сбойные оставить для повтора. Возвращает отправленные байты
size_t ui_flush(void);
// смена экрана: кадр уже нарисован целиком, в плоскости ещё старый. Шаг развёртки: строки
// [y0, y1) из кадра в плоскость и белая полоса развёртки под ними (прямо в плоскость).
// Изменённые области сбрасываются: после последнего шага (y1 = UI_H) плоскость = кадр
bool ui_reveal(int y0, int y1);
