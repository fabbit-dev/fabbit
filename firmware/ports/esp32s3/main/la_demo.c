#include "la_demo.h"

#include <string.h>
#include "driver/gpio.h"
#include "driver/ledc.h"
#include "driver/spi_master.h"
#include "driver/uart.h"
#include "esp_timer.h"
#include "fpga_link.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "la_capture.h"

static const int pins[] = {LA_DEMO_SQUARE_SLOW, LA_DEMO_SQUARE_FAST, LA_DEMO_PWM,
    LA_DEMO_UART_TX, LA_DEMO_SPI_CLK, LA_DEMO_SPI_MOSI, LA_DEMO_SPI_CS, LA_DEMO_MARKER};
static const int frequencies[] = {10000, 100000, 1000};
static SemaphoreHandle_t mutex;
static bool active, uart_owned, spi_owned;
static unsigned timers, channels;
static spi_device_handle_t spi;
static int64_t next_packet, next_duty;
static uint8_t sequence, duty_step;

static void floating(void)
{
    for (unsigned i = 0; i < sizeof pins / sizeof pins[0]; i++) {
        gpio_reset_pin(pins[i]);
        gpio_set_direction(pins[i], GPIO_MODE_INPUT);
        gpio_set_pull_mode(pins[i], GPIO_FLOATING);
    }
}

static void stop_locked(void)
{
    active = false;
    // Disconnect pads before tearing down peripherals. No driven idle on exit.
    floating();
    if (spi) { spi_bus_remove_device(spi); spi = NULL; }
    if (spi_owned) { spi_bus_free(SPI3_HOST); spi_owned = false; }
    if (uart_owned) { uart_driver_delete(UART_NUM_1); uart_owned = false; }
    for (unsigned i = 0; i < 3; i++) {
        if (channels & (1u << i)) {
            ledc_stop(LEDC_LOW_SPEED_MODE, (ledc_channel_t)i, 0);
            const ledc_channel_config_t c = {.speed_mode = LEDC_LOW_SPEED_MODE,
                .channel = (ledc_channel_t)i, .deconfigure = true};
            ledc_channel_config(&c);
        }
        if (timers & (1u << i)) {
            ledc_timer_pause(LEDC_LOW_SPEED_MODE, (ledc_timer_t)i);
            const ledc_timer_config_t t = {.speed_mode = LEDC_LOW_SPEED_MODE,
                .timer_num = (ledc_timer_t)i, .deconfigure = true};
            ledc_timer_config(&t);
        }
    }
    timers = channels = 0;
    floating();
}

esp_err_t la_demo_init(void)
{
    if (mutex) return ESP_OK;
    mutex = xSemaphoreCreateMutex();
    if (!mutex) return ESP_ERR_NO_MEM;
    floating();
    return ESP_OK;
}

void la_demo_stop(void)
{
    if (!mutex) return;
    xSemaphoreTake(mutex, portMAX_DELAY);
    if (active || uart_owned || spi_owned || spi || timers || channels) stop_locked();
    xSemaphoreGive(mutex);
}

bool la_demo_active(void)
{
    if (!mutex) return false;
    xSemaphoreTake(mutex, portMAX_DELAY);
    bool result = active;
    xSemaphoreGive(mutex);
    return result;
}

static esp_err_t present_locked(void)
{
    fl_id_t id;
    esp_err_t e = fl_id(&id);
    if (e == ESP_OK && (strcmp(id.magic, "FBPR") || id.profile != LA_PROFILE_ID))
        e = ESP_ERR_NOT_FOUND;
    uint32_t magic;
    if (e == ESP_OK) e = fl_csr_read(0, &magic, 1);
    if (e == ESP_OK && magic != LA_MAGIC) e = ESP_ERR_NOT_FOUND;
    if (e == ESP_OK) e = fl_csr_read(64, &magic, 1);
    if (e == ESP_OK && magic != 0x46424d56) e = ESP_ERR_NOT_FOUND;
    // Refuse two generators driving a possible shared input. Do not enable/disable P6 silently.
    if (e == ESP_OK) e = fl_csr_read(35, &magic, 1);
    if (e == ESP_OK && magic == 0x46424c47) {
        uint32_t control;
        e = fl_csr_read(32, &control, 1);
        if (e == ESP_OK && (control & 1u)) e = ESP_ERR_INVALID_STATE;
    }
    return e;
}

static esp_err_t setup_locked(void)
{
    for (unsigned i = 0; i < 3; i++) {
        const ledc_timer_config_t t = {.speed_mode = LEDC_LOW_SPEED_MODE,
            .duty_resolution = LEDC_TIMER_8_BIT, .timer_num = (ledc_timer_t)i,
            .freq_hz = frequencies[i], .clk_cfg = LEDC_USE_XTAL_CLK};
        esp_err_t e = ledc_timer_config(&t);
        if (e != ESP_OK) return e;
        timers |= 1u << i;
        const ledc_channel_config_t c = {.gpio_num = pins[i], .speed_mode = LEDC_LOW_SPEED_MODE,
            .channel = (ledc_channel_t)i, .timer_sel = (ledc_timer_t)i,
            .duty = i == 2 ? 64 : 128};
        e = ledc_channel_config(&c);
        if (e != ESP_OK) return e;
        channels |= 1u << i;
    }
    esp_err_t e = uart_driver_install(UART_NUM_1, 256, 0, 0, NULL, 0);
    if (e != ESP_OK) return e;
    uart_owned = true;
    const uart_config_t uart = {.baud_rate = 115200, .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE, .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE, .source_clk = UART_SCLK_XTAL};
    e = uart_param_config(UART_NUM_1, &uart);
    if (e != ESP_OK) return e;
    e = uart_set_pin(UART_NUM_1, LA_DEMO_UART_TX, UART_PIN_NO_CHANGE,
                     UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE);
    if (e != ESP_OK) return e;
    const spi_bus_config_t bus = {.sclk_io_num = LA_DEMO_SPI_CLK,
        .mosi_io_num = LA_DEMO_SPI_MOSI, .miso_io_num = -1,
        .quadwp_io_num = -1, .quadhd_io_num = -1,
        .data4_io_num = -1, .data5_io_num = -1, .data6_io_num = -1, .data7_io_num = -1,
        .max_transfer_sz = 4};
    e = spi_bus_initialize(SPI3_HOST, &bus, SPI_DMA_DISABLED);
    if (e != ESP_OK) return e;
    spi_owned = true;
    const spi_device_interface_config_t device = {.clock_speed_hz = 100000, .mode = 0,
        .spics_io_num = LA_DEMO_SPI_CS, .queue_size = 1, .flags = SPI_DEVICE_HALFDUPLEX};
    e = spi_bus_add_device(SPI3_HOST, &device, &spi);
    if (e != ESP_OK) return e;
    e = gpio_set_level(LA_DEMO_MARKER, 0);
    if (e != ESP_OK) return e;
    return gpio_set_direction(LA_DEMO_MARKER, GPIO_MODE_OUTPUT);
}

esp_err_t la_demo_start(void)
{
    if (!mutex) return ESP_ERR_INVALID_STATE;
    // Lock order is bus then demo everywhere; the exit hook only takes demo.
    fl_lock();
    xSemaphoreTake(mutex, portMAX_DELAY);
    esp_err_t e = present_locked();
    if (e == ESP_OK && !active) {
        e = setup_locked();
        if (e == ESP_OK) {
            active = true;
            sequence = duty_step = 0;
            next_packet = esp_timer_get_time();
            next_duty = next_packet + 500000;
        }
    }
    if (e != ESP_OK) stop_locked();
    xSemaphoreGive(mutex);
    fl_unlock();
    return e;
}

void la_demo_poll(void)
{
    if (!la_demo_active()) return;
    fl_lock();
    xSemaphoreTake(mutex, portMAX_DELAY);
    esp_err_t e = active ? present_locked() : ESP_ERR_INVALID_STATE;
    fl_unlock();
    int64_t now = esp_timer_get_time();
    if (e == ESP_OK && now >= next_packet) {
        // Marker encloses UART FABBIT\r\n followed by a mode-0 SPI packet.
        e = gpio_set_level(LA_DEMO_MARKER, 1);
        static const char text[] = "FABBIT\r\n";
        if (e == ESP_OK && uart_write_bytes(UART_NUM_1, text, sizeof text-1) != sizeof text-1)
            e = ESP_FAIL;
        if (e == ESP_OK) e = uart_wait_tx_done(UART_NUM_1, pdMS_TO_TICKS(20));
        spi_transaction_t packet = {.flags = SPI_TRANS_USE_TXDATA, .length = 32,
                                    .tx_data = {0xa5, 0x5a, sequence, 0x00}};
        if (e == ESP_OK) e = spi_device_transmit(spi, &packet);
        gpio_set_level(LA_DEMO_MARKER, 0);
        sequence++;
        next_packet = now + 20000;  // Task scheduling may extend the inter-packet gap.
    }
    if (e == ESP_OK && now >= next_duty) {
        static const uint32_t duty[] = {64, 128, 192, 128};
        duty_step = (duty_step+1)%4;
        e = ledc_set_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_2, duty[duty_step]);
        if (e == ESP_OK) e = ledc_update_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_2);
        next_duty = now + 500000;
    }
    if (e != ESP_OK) stop_locked();
    xSemaphoreGive(mutex);
}
