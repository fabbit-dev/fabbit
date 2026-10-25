// Шина ESP32-S3 -> ПЛИС: SPI2 через IO_MUX, QIO half-duplex. Пины по hardware_log §11.6,
// IRQ на макете GPIO5 (GPIO46 — стрэпинг, см. docs/protocol.md).
#include "fpga_link.h"

#include <stdlib.h>
#include <string.h>

#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_rom_sys.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#define PIN_CLK 12
#define PIN_CS 10
#define PIN_D0 11
#define PIN_D1 13
#define PIN_D2 14
#define PIN_D3 9
#define PIN_IRQ 5
// 8 dummy по протоколу. Автокомпенсацию ESP-IDF (лишний dummy на высоких частотах) выключаем
// SPI_DEVICE_NO_DUMMY; момент выдачи данных ПЛИС подстраивается командой TUNE (fl_tune).
#define DUMMY_CYCLES 8
static const uint8_t KEY[4] = {'F', 'B', 'K', 'Y'};
#define HALF (FL_BUF_SIZE / 2)

static const char *TAG = "fpga_link";
static spi_device_handle_t s_dev;
static uint32_t s_hz;
static uint8_t *s_dma;  // DMA-буфер во внутренней памяти
// шину делят консоль и задача кнопок: кадр целиком под замком, перенастройка шины тоже
static SemaphoreHandle_t s_lock;

void fl_lock(void) { xSemaphoreTakeRecursive(s_lock, portMAX_DELAY); }
void fl_unlock(void) { xSemaphoreGiveRecursive(s_lock); }

static esp_err_t add_device(uint32_t hz)
{
    spi_device_interface_config_t dev = {
        .command_bits = 8,
        .address_bits = 24,
        .mode = 0,
        .clock_speed_hz = (int)hz,
        .spics_io_num = PIN_CS,
        .flags = SPI_DEVICE_HALFDUPLEX | SPI_DEVICE_NO_DUMMY,
        .queue_size = 2,
    };
    ESP_RETURN_ON_ERROR(spi_bus_add_device(SPI2_HOST, &dev, &s_dev), TAG, "add_device");
    int real = 0;
    spi_device_get_actual_freq(s_dev, &real);
    s_hz = (uint32_t)real * 1000;
    return ESP_OK;
}

esp_err_t fl_init(uint32_t hz)
{
    if (!s_lock) s_lock = xSemaphoreCreateRecursiveMutex();
    if (!s_lock) return ESP_ERR_NO_MEM;
    spi_bus_config_t bus = {
        .sclk_io_num = PIN_CLK,
        .data0_io_num = PIN_D0,
        .data1_io_num = PIN_D1,
        .data2_io_num = PIN_D2,
        .data3_io_num = PIN_D3,
        .data4_io_num = -1,
        .data5_io_num = -1,
        .data6_io_num = -1,
        .data7_io_num = -1,
        .max_transfer_sz = FL_BUF_SIZE + 64,
        // без SPICOMMON_BUSFLAG_QUAD: в ESP-IDF 6.1 spi_common.c проверяет `flags & OCTAL` (а OCTAL =
        // QUAD|IO4_IO7) и после quad перетирает SCK/IO0..3 октальной функцией IO_MUX 2. Quad драйвер
        // всё равно определяет по наличию WP/HD.
        .flags = SPICOMMON_BUSFLAG_MASTER | SPICOMMON_BUSFLAG_IOMUX_PINS,
    };
    ESP_RETURN_ON_ERROR(spi_bus_initialize(SPI2_HOST, &bus, SPI_DMA_CH_AUTO), TAG, "bus");
    gpio_config_t irq = {
        .pin_bit_mask = 1ULL << PIN_IRQ,
        .mode = GPIO_MODE_INPUT,
        .pull_down_en = GPIO_PULLDOWN_ENABLE,  // ПЛИС не сконфигурирована: читаем "занят"
    };
    gpio_config(&irq);
    s_dma = heap_caps_malloc(FL_BUF_SIZE, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    if (!s_dma) return ESP_ERR_NO_MEM;
    ESP_RETURN_ON_ERROR(add_device(hz), TAG, "device");
    // момент выдачи данных, подобранный на макете командой tune: 16 передних фронтов, данные
    // меняются по заднему фронту. Работает на 1, 5 и 10 МГц (выше не тянет оверсемплинг 100 МГц)
    return fl_tune(16, true);
}

static esp_err_t fl_wiretest_locked(void)
{
    static const int pins[] = {PIN_CLK, PIN_CS, PIN_D0, PIN_D1, PIN_D2, PIN_D3, PIN_IRQ};
    uint32_t hz = s_hz;
    ESP_RETURN_ON_ERROR(spi_bus_remove_device(s_dev), TAG, "remove");
    ESP_RETURN_ON_ERROR(spi_bus_free(SPI2_HOST), TAG, "free");
    for (int i = 0; i < 7; i++) {
        gpio_reset_pin(pins[i]);
        gpio_set_direction(pins[i], GPIO_MODE_OUTPUT);
        gpio_set_level(pins[i], 0);
    }
    vTaskDelay(pdMS_TO_TICKS(300));
    for (int i = 0; i < 7; i++) {
        gpio_set_level(pins[i], 1);
        vTaskDelay(pdMS_TO_TICKS(300));
        gpio_set_level(pins[i], 0);
    }
    vTaskDelay(pdMS_TO_TICKS(300));
    for (int i = 0; i < 7; i++) gpio_reset_pin(pins[i]);
    free(s_dma);
    s_dma = NULL;
    return fl_init(hz);
}

esp_err_t fl_wiretest(void)
{
    fl_lock();
    esp_err_t e = fl_wiretest_locked();
    fl_unlock();
    return e;
}

static esp_err_t fl_pins_locked(uint8_t *with_pd, uint8_t *with_pu)
{
    static const int pins[] = {PIN_CLK, PIN_CS, PIN_D0, PIN_D1, PIN_D2, PIN_D3, PIN_IRQ};
    uint32_t hz = s_hz;
    ESP_RETURN_ON_ERROR(spi_bus_remove_device(s_dev), TAG, "remove");
    ESP_RETURN_ON_ERROR(spi_bus_free(SPI2_HOST), TAG, "free");
    *with_pd = *with_pu = 0;
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < 7; i++) {
            gpio_reset_pin(pins[i]);
            gpio_set_direction(pins[i], GPIO_MODE_INPUT);
            gpio_set_pull_mode(pins[i], pass ? GPIO_PULLUP_ONLY : GPIO_PULLDOWN_ONLY);
        }
        vTaskDelay(pdMS_TO_TICKS(20));
        for (int i = 0; i < 7; i++)
            if (gpio_get_level(pins[i])) *(pass ? with_pu : with_pd) |= 1 << i;
    }
    for (int i = 0; i < 7; i++) gpio_reset_pin(pins[i]);
    free(s_dma);
    s_dma = NULL;
    return fl_init(hz);
}

esp_err_t fl_pins(uint8_t *with_pd, uint8_t *with_pu)
{
    fl_lock();
    esp_err_t e = fl_pins_locked(with_pd, with_pu);
    fl_unlock();
    return e;
}

static esp_err_t fl_set_freq_locked(uint32_t hz)
{
    ESP_RETURN_ON_ERROR(spi_bus_remove_device(s_dev), TAG, "remove");
    return add_device(hz);
}

esp_err_t fl_set_freq(uint32_t hz)
{
    fl_lock();
    esp_err_t e = fl_set_freq_locked(hz);
    fl_unlock();
    return e;
}

uint32_t fl_get_freq(void) { return s_hz; }

static esp_err_t xfer(uint8_t cmd, uint32_t addr, const void *tx, void *rx, size_t len)
{
    spi_transaction_ext_t t = {0};
    t.base.flags = SPI_TRANS_MODE_QIO | SPI_TRANS_MULTILINE_CMD | SPI_TRANS_MULTILINE_ADDR;
    t.base.cmd = cmd;
    t.base.addr = addr & 0xFFFFFF;
    if (tx && len) {
        t.base.tx_buffer = s_dma;
        t.base.length = len * 8;
    } else if (rx && len) {
        t.base.flags |= SPI_TRANS_VARIABLE_DUMMY;
        t.dummy_bits = DUMMY_CYCLES;
        t.base.rx_buffer = s_dma;
        t.base.rxlength = len * 8;
    }
    fl_lock();
    if (tx && len) memcpy(s_dma, tx, len);
    esp_err_t err = spi_device_polling_transmit(s_dev, &t.base);
    if (err == ESP_OK && rx && len) memcpy(rx, s_dma, len);
    fl_unlock();
    return err;
}

esp_err_t fl_write(uint8_t cmd, uint32_t addr, const void *data, size_t len)
{
    if (len > FL_BUF_SIZE) return ESP_ERR_INVALID_SIZE;
    return xfer(cmd, addr, data, NULL, len);
}

esp_err_t fl_read(uint8_t cmd, uint32_t addr, void *data, size_t len)
{
    if (len > FL_BUF_SIZE) return ESP_ERR_INVALID_SIZE;
    return xfer(cmd, addr, NULL, data, len);
}

esp_err_t fl_id(fl_id_t *id)
{
    uint8_t b[8];
    ESP_RETURN_ON_ERROR(fl_read(FL_CMD_ID, 0, b, sizeof b), TAG, "id");
    memcpy(id->magic, b, 4);
    id->magic[4] = 0;
    id->version = b[4];
    id->mode = b[5];
    id->profile = (uint16_t)(b[6] << 8 | b[7]);
    return ESP_OK;
}

esp_err_t fl_status(fl_status_t *st)
{
    uint8_t b[8];
    ESP_RETURN_ON_ERROR(fl_read(FL_CMD_STATUS, 0, b, sizeof b), TAG, "status");
    st->busy = b[0] & 1;
    st->error = (b[0] >> 1) & 1;
    st->err_code = b[1];
    st->bootsts = (uint32_t)b[2] << 24 | b[3] << 16 | b[4] << 8 | b[5];
    return ESP_OK;
}

esp_err_t fl_wait_idle(uint32_t timeout_ms)
{
    int64_t end = esp_timer_get_time() + (int64_t)timeout_ms * 1000;
    esp_rom_delay_us(2);  // IRQ падает через пару тактов ПЛИС после CS#
    while (!gpio_get_level(PIN_IRQ)) {
        if (esp_timer_get_time() > end) return ESP_ERR_TIMEOUT;
        if (timeout_ms > 20) vTaskDelay(1);
    }
    fl_status_t st;
    ESP_RETURN_ON_ERROR(fl_status(&st), TAG, "status");
    if (st.err_code) {
        ESP_LOGE(TAG, "ошибка golden: %u", st.err_code);
        return ESP_FAIL;
    }
    return ESP_OK;
}

esp_err_t fl_buf_write(uint32_t off, const void *data, size_t len)
{
    return fl_write(FL_CMD_BUF_W, off, data, len);
}

esp_err_t fl_buf_read(uint32_t off, void *data, size_t len)
{
    return fl_read(FL_CMD_BUF_R, off, data, len);
}

esp_err_t fl_param(uint32_t len, uint32_t buf_off)
{
    uint8_t b[8] = {len >> 24, len >> 16, len >> 8, len, buf_off >> 24, buf_off >> 16,
                    buf_off >> 8, buf_off};
    return fl_write(FL_CMD_PARAM, 0, b, sizeof b);
}

esp_err_t fl_result(uint32_t *v)
{
    uint8_t b[4];
    ESP_RETURN_ON_ERROR(fl_read(FL_CMD_RESULT, 0, b, sizeof b), TAG, "result");
    *v = (uint32_t)b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3];
    return ESP_OK;
}

esp_err_t fl_tune(uint8_t rd_start, bool rd_fall);

static esp_err_t simple(uint8_t cmd, uint32_t addr, uint32_t timeout_ms)
{
    // ERASE/PROG/BOOT ПЛИС исполняет только с ключом в кадре
    bool keyed = cmd == FL_CMD_ERASE || cmd == FL_CMD_PROG || cmd == FL_CMD_BOOT ||
                 cmd == FL_CMD_FL_WRSR || cmd == FL_CMD_SET_WDT;
    ESP_RETURN_ON_ERROR(fl_write(cmd, addr, keyed ? KEY : NULL, keyed ? 4 : 0), TAG, "cmd");
    return fl_wait_idle(timeout_ms);
}

esp_err_t fl_tune(uint8_t rd_start, bool rd_fall)
{
    return fl_write(FL_CMD_TUNE, rd_start | (rd_fall ? 0x100 : 0), KEY, 4);
}

esp_err_t fl_flash_id(uint32_t *jedec)
{
    ESP_RETURN_ON_ERROR(simple(FL_CMD_FL_ID, 0, 100), TAG, "fl_id");
    return fl_result(jedec);
}

esp_err_t fl_flash_erase64k(uint32_t addr) { return simple(FL_CMD_ERASE, addr, 3000); }

esp_err_t fl_flash_sr(uint8_t *sr, uint8_t *cr)
{
    uint32_t v;
    ESP_RETURN_ON_ERROR(simple(FL_CMD_FL_SR, 0, 100), TAG, "rdsr");
    ESP_RETURN_ON_ERROR(fl_result(&v), TAG, "res");
    *sr = (uint8_t)v;
    ESP_RETURN_ON_ERROR(simple(FL_CMD_FL_SR, 1, 100), TAG, "rdcr");
    ESP_RETURN_ON_ERROR(fl_result(&v), TAG, "res");
    *cr = (uint8_t)v;
    return ESP_OK;
}

esp_err_t fl_flash_wrsr(uint8_t sr, uint8_t cr)
{
    return simple(FL_CMD_FL_WRSR, (uint32_t)cr << 8 | sr, 1000);
}

esp_err_t fl_flash_program(uint32_t addr, const void *data, size_t len)
{
    ESP_RETURN_ON_ERROR(fl_buf_write(0, data, len), TAG, "buf");
    ESP_RETURN_ON_ERROR(fl_param(len, 0), TAG, "param");
    return simple(FL_CMD_PROG, addr, 1000);
}

esp_err_t fl_flash_write_image(uint32_t addr, const uint8_t *data, size_t len,
                               void (*progress)(size_t, size_t))
{
    if (addr < FL_PROT_TOP || (addr & 0xFFFF)) return ESP_ERR_INVALID_ARG;
    size_t done = 0;
    int half = 0;
    bool prog_running = false;
    while (done < len) {
        size_t n = len - done > HALF ? HALF : len - done;
        uint32_t a = addr + done;
        // загрузить кусок в свободную половину, пока прошлый пишется во флеш
        ESP_RETURN_ON_ERROR(fl_buf_write(half * HALF, data + done, n), TAG, "buf");
        if (prog_running) ESP_RETURN_ON_ERROR(fl_wait_idle(1000), TAG, "prog");
        if ((a & 0xFFFF) == 0) ESP_RETURN_ON_ERROR(fl_flash_erase64k(a), TAG, "erase %08lx",
                                                    (unsigned long)a);
        ESP_RETURN_ON_ERROR(fl_param(n, half * HALF), TAG, "param");
        ESP_RETURN_ON_ERROR(fl_write(FL_CMD_PROG, a, KEY, 4), TAG, "prog");
        prog_running = true;
        done += n;
        half ^= 1;
        if (progress) progress(done, len);
    }
    return fl_wait_idle(1000);
}

esp_err_t fl_flash_read(uint32_t addr, void *data, size_t len)
{
    uint8_t *p = data;
    while (len) {
        size_t n = len > FL_BUF_SIZE ? FL_BUF_SIZE : len;
        ESP_RETURN_ON_ERROR(fl_param(n, 0), TAG, "param");
        ESP_RETURN_ON_ERROR(simple(FL_CMD_READ, addr, 1000), TAG, "read");
        ESP_RETURN_ON_ERROR(fl_buf_read(0, p, n), TAG, "buf");
        p += n;
        addr += n;
        len -= n;
    }
    return ESP_OK;
}

esp_err_t fl_flash_crc(uint32_t addr, uint32_t len, uint32_t *crc)
{
    ESP_RETURN_ON_ERROR(fl_param(len, 0), TAG, "param");
    ESP_RETURN_ON_ERROR(simple(FL_CMD_CRC, addr, 10000), TAG, "crc");
    return fl_result(crc);
}

esp_err_t fl_boot(uint32_t addr) { return fl_write(FL_CMD_BOOT, addr, KEY, 4); }

esp_err_t fl_set_wdt(uint32_t units) { return simple(FL_CMD_SET_WDT, units & 0xFFFFFF, 100); }

esp_err_t fl_reboot_golden(void) { return fl_write(FL_CMD_REBOOT_GOLDEN, 0, KEY, 4); }

esp_err_t fl_pad(uint16_t pad0, uint16_t pad1)
{
    const uint8_t b[4] = {pad1 >> 8, pad1 & 0xFF, pad0 >> 8, pad0 & 0xFF};
    return fl_write(FL_CMD_PAD, 0, b, 4);
}

esp_err_t fl_csr_write(uint8_t idx, const uint32_t *v, size_t n)
{
    uint8_t b[256];
    if (n > sizeof b / 4) return ESP_ERR_INVALID_SIZE;
    for (size_t i = 0; i < n; i++) {
        b[4 * i] = v[i] >> 24;
        b[4 * i + 1] = v[i] >> 16;
        b[4 * i + 2] = v[i] >> 8;
        b[4 * i + 3] = v[i];
    }
    return fl_write(FL_CMD_CSR_W, idx, b, 4 * n);
}

esp_err_t fl_csr_read(uint8_t idx, uint32_t *v, size_t n)
{
    uint8_t b[256];
    if (n > sizeof b / 4) return ESP_ERR_INVALID_SIZE;
    ESP_RETURN_ON_ERROR(fl_read(FL_CMD_CSR_R, idx, b, 4 * n), TAG, "csr");
    for (size_t i = 0; i < n; i++)
        v[i] = (uint32_t)b[4 * i] << 24 | b[4 * i + 1] << 16 | b[4 * i + 2] << 8 | b[4 * i + 3];
    return ESP_OK;
}

uint32_t fl_crc32(uint32_t crc, const uint8_t *p, size_t n)
{
    crc = ~crc;
    while (n--) {
        crc ^= *p++;
        for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320u & -(crc & 1));
    }
    return ~crc;
}

static int bs_part(uint8_t b, char *o, size_t n)
{
    static const char *names[] = {"VALID", "FALLBACK", "IPROG", "WATCHDOG", "ID_ERR", "CRC_ERR",
                                  "WRAP_ERR", "B7"};
    int k = 0;
    for (int i = 0; i < 8 && (size_t)k < n; i++)
        if (b >> i & 1) k += snprintf(o + k, n - k, "%s%s", k ? "," : "", names[i]);
    if (!k && n) k = snprintf(o, n, "-");
    return k;
}

void fl_bootsts_str(uint32_t v, char *out, size_t n)
{
    int k = snprintf(out, n, "сейчас: ");
    k += bs_part(v & 0xFF, out + k, n - k);
    k += snprintf(out + k, n - k, "; до этого: ");
    bs_part((v >> 8) & 0xFF, out + k, n - k);
}
