// Portable frozen-capture viewport. Samples remain in FPGA; port reads bounded windows.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define LAV_COLUMNS 560u
typedef enum { LAV_READY, LAV_WAIT, LAV_DONE, LAV_ERROR } lav_state_t;
typedef enum { LAV_ANY, LAV_RISE, LAV_FALL } lav_trigger_t;
typedef struct {
    lav_state_t state;
    lav_trigger_t trigger;
    uint32_t count, trigger_index, base_hz, divider;
    uint32_t offset, span;
    unsigned channel;
} lav_view_t;
typedef struct { uint16_t first, last, low, high; } lav_column_t;

void lav_init(lav_view_t *v);
void lav_capture(lav_view_t *v, uint32_t count, uint32_t trigger_index,
                 uint32_t base_hz, uint32_t divider);
void lav_zoom(lav_view_t *v, bool in);
void lav_pan(lav_view_t *v, bool right);
// Partition a viewport into columns without losing narrow pulses. Empty columns repeat a sample.
void lav_range(const lav_view_t *v, unsigned column, uint32_t *begin, uint32_t *end);
void lav_column(lav_column_t *out, const uint8_t *le16, size_t samples);
void lav_draw(const lav_view_t *v, const lav_column_t columns[LAV_COLUMNS]);
