// Менеджер профилей: .fbp из /data, таблица слотов во флеше ПЛИС (PM_TABLE_ADDR), кэш по CRC.
#include "profile_mgr.h"

#include <dirent.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_vfs_fat.h"
#include "fpga_link.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "profile";
#define ROOT "/data"

esp_err_t pm_init(void)
{
    esp_vfs_fat_mount_config_t cfg = {.max_files = 4, .format_if_mount_failed = false};
    return esp_vfs_fat_spiflash_mount_ro(ROOT, "storage", &cfg);
}

static bool header_ok(const pm_header_t *h)
{
    return !memcmp(h->magic, "FBP1", 4) && h->version == 1 &&
           fl_crc32(0, (const uint8_t *)h, 60) == h->hdr_crc && h->len <= PM_SLOT_SIZE;
}

static esp_err_t read_header(const char *path, pm_header_t *h)
{
    FILE *f = fopen(path, "rb");
    if (!f) return ESP_ERR_NOT_FOUND;
    size_t n = fread(h, 1, sizeof *h, f);
    fclose(f);
    return (n == sizeof *h && header_ok(h)) ? ESP_OK : ESP_ERR_INVALID_CRC;
}

void pm_list(void)
{
    DIR *d = opendir(ROOT);
    if (!d) {
        printf("нет %s\n", ROOT);
        return;
    }
    struct dirent *e;
    while ((e = readdir(d))) {
        size_t l = strlen(e->d_name);
        if (l < 5 || strcasecmp(e->d_name + l - 4, ".fbp")) continue;
        char path[300];
        snprintf(path, sizeof path, ROOT "/%s", e->d_name);
        pm_header_t h;
        if (read_header(path, &h) == ESP_OK)
            printf("%-14s id %-3u %-24.32s %7" PRIu32 " Б  CRC %08" PRIx32 "\n", e->d_name, h.id,
                   h.name, h.len, h.crc);
        else
            printf("%-14s повреждён заголовок\n", e->d_name);
    }
    closedir(d);
}

static uint32_t table_crc(const pm_table_t *t)
{
    return fl_crc32(0, (const uint8_t *)t, offsetof(pm_table_t, crc));
}

static void table_read(pm_table_t *t)
{
    if (fl_flash_read(PM_TABLE_ADDR, t, sizeof *t) != ESP_OK || memcmp(t->magic, "FBST", 4) ||
        t->crc != table_crc(t)) {
        memset(t, 0, sizeof *t);
        memcpy(t->magic, "FBST", 4);
        t->version = 1;
    }
}

static esp_err_t table_write(pm_table_t *t)
{
    t->seq++;
    t->crc = table_crc(t);
    ESP_RETURN_ON_ERROR(fl_flash_erase64k(PM_TABLE_ADDR), TAG, "erase table");
    return fl_flash_program(PM_TABLE_ADDR, t, sizeof *t);
}

esp_err_t pm_slots(void)
{
    pm_table_t t;
    table_read(&t);
    printf("таблица seq %" PRIu32 "\n", t.seq);
    for (int i = 0; i < PM_SLOTS; i++) {
        pm_slot_t *s = &t.slot[i];
        printf("слот %d @%06" PRIx32 ": ", i, (uint32_t)(PM_SLOT_BASE + i * PM_SLOT_SIZE));
        if (!s->crc) printf("пуст\n");
        else
            printf("id %u, %" PRIu32 " Б, CRC %08" PRIx32 ", запись #%" PRIu32 "\n", s->id, s->len,
                   s->crc, s->used);
    }
    return ESP_OK;
}

static pm_progress_cb s_cb;
static void *s_ctx;

static void stage(const char *what, int pct)
{
    if (s_cb) s_cb(s_ctx, what, pct);
}

static void progress(size_t done, size_t total)
{
    if (done == total || done % (512 * 1024) == 0) printf("  запись %u/%u\n", done, total);
    if (done == total || done % (64 * 1024) == 0) stage("запись ядра в слот", (int)(done * 100 / total));
}

esp_err_t pm_load(const char *file, bool force_write) { return pm_load_cb(file, force_write, NULL, NULL); }

esp_err_t pm_load_cb(const char *file, bool force_write, pm_progress_cb cb, void *ctx)
{
    s_cb = cb;
    s_ctx = ctx;
    char path[300];
    snprintf(path, sizeof path, ROOT "/%s%s", file, strchr(file, '.') ? "" : ".fbp");
    pm_header_t h;
    esp_err_t err = read_header(path, &h);
    ESP_RETURN_ON_ERROR(err, TAG, "заголовок %s", path);

    int64_t t0 = esp_timer_get_time();
    stage("проверка слотов", -1);
    // кэш: слот с тем же CRC и длиной, содержимое во флеше сверяется CRC (считает ПЛИС)
    pm_table_t t;
    table_read(&t);
    int slot = -1;
    for (int i = 0; i < PM_SLOTS && !force_write; i++)
        if (t.slot[i].crc == h.crc && t.slot[i].len == h.len) {
            uint32_t c = 0;
            if (fl_flash_crc(PM_SLOT_BASE + i * PM_SLOT_SIZE, h.len, &c) == ESP_OK && c == h.crc)
                slot = i;
            else
                ESP_LOGW(TAG, "слот %d: CRC во флеше не сошёлся, перезапись", i);
            break;
        }
    int64_t t_file = esp_timer_get_time();  // при промахе ниже: чтение файла
    uint8_t *img = NULL;
    if (slot < 0) {
        img = heap_caps_malloc(h.len, MALLOC_CAP_SPIRAM);
        if (!img) return ESP_ERR_NO_MEM;
        FILE *f = fopen(path, "rb");
        fseek(f, sizeof h, SEEK_SET);
        size_t n = fread(img, 1, h.len, f);
        fclose(f);
        if (n != h.len || fl_crc32(0, img, h.len) != h.crc) {
            free(img);
            ESP_LOGE(TAG, "образ повреждён");
            return ESP_ERR_INVALID_CRC;
        }
    }
    int64_t t_check = esp_timer_get_time();
    bool written = false;
    if (slot < 0) {
        // пустой слот, иначе самый давно записанный
        uint32_t best = UINT32_MAX;
        for (int i = 0; i < PM_SLOTS; i++) {
            uint32_t u = t.slot[i].crc ? t.slot[i].used : 0;
            if (u < best) {
                best = u;
                slot = i;
            }
        }
        uint32_t addr = PM_SLOT_BASE + slot * PM_SLOT_SIZE;
        printf("запись в слот %d @%06" PRIx32 "\n", slot, addr);
        // сначала пометить слот пустым: обрыв записи не оставит в таблице битый образ
        uint32_t maxused = 0;
        for (int i = 0; i < PM_SLOTS; i++)
            if (t.slot[i].used > maxused) maxused = t.slot[i].used;
        memset(&t.slot[slot], 0, sizeof t.slot[slot]);
        err = table_write(&t);
        if (err == ESP_OK) err = fl_flash_write_image(addr, img, h.len, progress);
        uint32_t c = 0;
        if (err == ESP_OK) err = fl_flash_crc(addr, h.len, &c);
        if (err == ESP_OK && c != h.crc) err = ESP_ERR_INVALID_CRC;
        if (err == ESP_OK) {
            t.slot[slot] = (pm_slot_t){.crc = h.crc, .len = h.len, .id = h.id, .used = maxused + 1};
            err = table_write(&t);
        }
        written = true;
    }
    free(img);
    ESP_RETURN_ON_ERROR(err, TAG, "запись слота");
    int64_t t_slot = esp_timer_get_time();

    uint32_t addr = PM_SLOT_BASE + slot * PM_SLOT_SIZE;
    stage("запуск ядра", -1);
    ESP_RETURN_ON_ERROR(fl_set_wdt(PM_WDT_UNITS), TAG, "wdt");
    ESP_RETURN_ON_ERROR(fl_boot(addr), TAG, "boot");
    int64_t t_boot = esp_timer_get_time();
    fl_id_t id = {0};
    bool ok = false;
    while (esp_timer_get_time() - t_boot < 5000000) {
        vTaskDelay(pdMS_TO_TICKS(20));
        fl_tune(16, true);  // ПЛИС после загрузки или отката могла сбросить настройку выдачи
        if (fl_id(&id) == ESP_OK && !memcmp(id.magic, "FBPR", 4) && id.profile == h.id) {
            ok = true;
            break;
        }
    }
    int64_t t_up = esp_timer_get_time();
    printf("проверка кэша %lld мс, файл %lld мс, %s %lld мс, старт профиля %lld мс, всего %lld мс\n",
           (t_file - t0) / 1000, (t_check - t_file) / 1000, written ? "запись" : "слот из кэша",
           (t_slot - t_check) / 1000, (t_up - t_boot) / 1000, (t_up - t0) / 1000);
    if (!ok) {
        fl_status_t st = {0};
        if (!memcmp(id.magic, "FBGL", 4) && fl_wait_idle(1500) == ESP_OK && fl_status(&st) == ESP_OK)
        {
            char bs[96];
            fl_bootsts_str(st.bootsts, bs, sizeof bs);
            ESP_LOGE(TAG, "откат на golden, BOOTSTS %08" PRIx32 " (%s)", st.bootsts, bs);
        }
        else
            ESP_LOGE(TAG, "профиль не ответил (ID magic %.4s)", id.magic);
        return ESP_FAIL;
    }
    printf("профиль %u \"%.32s\" запущен в слоте %d\n", h.id, h.name, slot);
    return ESP_OK;
}
