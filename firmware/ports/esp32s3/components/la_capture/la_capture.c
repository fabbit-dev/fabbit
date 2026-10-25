#include "la_capture.h"

#include <stdbool.h>
#include <string.h>

#include "fpga_link.h"

static esp_err_t present_locked(void)
{
    fl_id_t id;
    esp_err_t e = fl_id(&id);
    if (e != ESP_OK) return e;
    if (strcmp(id.magic, "FBPR") || id.profile != LA_PROFILE_ID) return ESP_ERR_NOT_FOUND;
    uint32_t magic;
    e = fl_csr_read(0, &magic, 1);
    if (e == ESP_OK && magic != LA_MAGIC) e = ESP_ERR_NOT_FOUND;
    return e;
}

static bool same_snapshot(const la_status_t *a, const la_status_t *b)
{
    return a->flags == b->flags && a->capacity == b->capacity && a->base_hz == b->base_hz &&
           a->count == b->count && a->trigger_index == b->trigger_index &&
           a->epoch == b->epoch && a->divider == b->divider && a->source == b->source;
}

static esp_err_t status_locked(la_status_t *out)
{
    esp_err_t e = present_locked();
    if (e != ESP_OK) return e;
    // A capture may finish during the CSR burst. Retry a torn status once; never mix epochs.
    for (int attempt = 0; attempt < 2; attempt++) {
        uint32_t r[18], flags, epoch;
        e = fl_csr_read(0, r, 18);
        if (e == ESP_OK) e = fl_csr_read(2, &flags, 1);
        if (e == ESP_OK) e = fl_csr_read(14, &epoch, 1);
        if (e != ESP_OK) return e;
        if (r[0] != LA_MAGIC) return ESP_ERR_NOT_FOUND;
        if (r[2] != flags || r[14] != epoch) continue;
        la_status_t s = {.flags = flags, .capacity = r[3], .base_hz = r[4],
                         .count = r[12], .trigger_index = r[13], .epoch = epoch,
                         .divider = r[15], .source = r[17]};
        if ((flags & ~15u) || !s.capacity || s.capacity > LA_MAX_SAMPLES ||
            s.base_hz != 100000000u || s.source > 1 || s.count > s.capacity ||
            ((flags & LA_DONE) && ((flags & (LA_BUSY | LA_BAD_CONFIG)) ||
              !(flags & LA_TRIGGERED) || !s.count || s.trigger_index >= s.count)) ||
            (!(flags & LA_DONE) && (s.count || s.trigger_index)))
            return ESP_ERR_INVALID_RESPONSE;
        *out = s;
        return ESP_OK;
    }
    return ESP_ERR_INVALID_STATE;
}

esp_err_t la_status(la_status_t *status)
{
    if (!status) return ESP_ERR_INVALID_ARG;
    memset(status, 0, sizeof *status);
    fl_lock();
    esp_err_t e = status_locked(status);
    fl_unlock();
    return e;
}

esp_err_t la_arm(const la_config_t *config, la_status_t *status)
{
    if (!config || !status) return ESP_ERR_INVALID_ARG;
    memset(status, 0, sizeof *status);
    if (!config->total || config->total > LA_MAX_SAMPLES || !config->post ||
        config->post > config->total || config->source > 1 || (config->rise & config->fall))
        return ESP_ERR_INVALID_ARG;
    fl_lock();
    la_status_t before;
    esp_err_t e = status_locked(&before);
    if (e == ESP_OK && config->total > before.capacity) e = ESP_ERR_INVALID_ARG;
    const uint32_t words[] = {config->total, config->post, config->divider, config->mask,
                              config->value, config->rise, config->fall};
    if (e == ESP_OK) e = fl_csr_write(5, words, 7);
    if (e == ESP_OK) e = fl_csr_set(16, config->source);
    // If configuration writes fail, do not issue ARM with a partial configuration.
    if (e == ESP_OK) e = fl_csr_set(1, LA_KEY | 1);
    if (e == ESP_OK) e = status_locked(status);
    if (e == ESP_OK && (status->epoch != before.epoch + 1u ||
                       (status->flags & LA_BAD_CONFIG) ||
                       !(status->flags & (LA_BUSY | LA_DONE)))) e = ESP_ERR_INVALID_RESPONSE;
    fl_unlock();
    return e;
}

esp_err_t la_abort(void)
{
    fl_lock();
    esp_err_t e = present_locked();
    if (e == ESP_OK) e = fl_csr_set(1, LA_KEY | 2);
    fl_unlock();
    return e;
}

esp_err_t la_read(uint32_t epoch, uint32_t offset, void *data, size_t size, la_status_t *status)
{
    if (!data || !size || size > FL_BUF_SIZE || !status) return ESP_ERR_INVALID_ARG;
    memset(data, 0, size);
    memset(status, 0, sizeof *status);
    fl_lock();
    la_status_t before, after;
    esp_err_t e = status_locked(&before);
    if (e == ESP_OK && before.epoch != epoch) e = ESP_ERR_INVALID_STATE;
    if (e == ESP_OK && !(before.flags & LA_DONE)) e = ESP_ERR_NOT_FINISHED;
    if (e == ESP_OK && (offset > before.count * 2u || size > before.count * 2u - offset))
        e = ESP_ERR_INVALID_ARG;
    if (e == ESP_OK) e = fl_read(FL_CMD_CAPTURE_R, offset, data, size);
    if (e == ESP_OK) e = status_locked(&after);
    if (e == ESP_OK && !same_snapshot(&before, &after)) e = ESP_ERR_INVALID_STATE;
    if (e == ESP_OK) *status = before;
    else memset(data, 0, size);
    fl_unlock();
    return e;
}
