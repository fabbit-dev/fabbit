#pragma once
#include "esp_err.h"
#include "freertos/FreeRTOS.h"
#include <stddef.h>
enum { UART_NUM_1 = 1, UART_DATA_8_BITS = 8, UART_PARITY_DISABLE,
    UART_STOP_BITS_1, UART_HW_FLOWCTRL_DISABLE, UART_SCLK_XTAL, UART_PIN_NO_CHANGE = -1 };
typedef struct { int baud_rate, data_bits, parity, stop_bits, flow_ctrl, source_clk; } uart_config_t;
esp_err_t uart_driver_install(int port, int rx, int tx, int queue, void *handle, int flags);
esp_err_t uart_driver_delete(int port);
esp_err_t uart_param_config(int port, const uart_config_t *config);
esp_err_t uart_set_pin(int port, int tx, int rx, int rts, int cts);
int uart_write_bytes(int port, const void *data, size_t size);
esp_err_t uart_wait_tx_done(int port, TickType_t timeout);
