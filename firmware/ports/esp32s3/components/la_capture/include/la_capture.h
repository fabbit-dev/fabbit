// Клиент профиля ЛА: CSR и адресное чтение BRAM (docs/bus-protocol.md).
#pragma once
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

enum { LA_BUSY = 1, LA_TRIGGERED = 2, LA_DONE = 4, LA_BAD_CONFIG = 8 };
#define LA_PROFILE_ID 0x4C41u
#define LA_MAGIC 0x46424C41u
#define LA_KEY 0x4C410000u
#define LA_MAX_SAMPLES 131072u

typedef struct {
    uint32_t flags, capacity, base_hz;
    uint32_t count, trigger_index, epoch, divider, source;
} la_status_t;

typedef struct {
    uint32_t total, post, divider;
    uint16_t mask, value, rise, fall;
    uint32_t source;  // 0=P2, 1=counter
} la_config_t;

// Every operation owns the link lock. No printing or callbacks while the lock is held.
// NOT_FOUND: not LA; INVALID_RESPONSE: malformed descriptor; NOT_FINISHED: not frozen;
// INVALID_STATE: epoch/descriptor changed; transport errors pass through unchanged.
esp_err_t la_status(la_status_t *status);
esp_err_t la_arm(const la_config_t *config, la_status_t *status);
esp_err_t la_abort(void);
// Reads at most FL_BUF_SIZE bytes; arbitrary byte offsets, no cursor. On failure data is zeroed.
// Metadata must match before/after the block. Host must also check epoch after the final block.
esp_err_t la_read(uint32_t epoch, uint32_t offset, void *data, size_t size, la_status_t *status);
