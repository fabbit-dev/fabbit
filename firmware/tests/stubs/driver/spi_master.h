#pragma once
#include <stdint.h>
#include <stddef.h>
#include "esp_err.h"
enum { SPI2_HOST = 2, SPI3_HOST = 3, SPI_DMA_DISABLED = 0, SPI_DMA_CH_AUTO = 1,
    SPI_DEVICE_HALFDUPLEX = 1, SPI_DEVICE_NO_DUMMY = 2, SPI_TRANS_USE_TXDATA = 4,
    SPI_TRANS_MODE_QIO = 8, SPI_TRANS_MULTILINE_CMD = 16, SPI_TRANS_MULTILINE_ADDR = 32,
    SPI_TRANS_VARIABLE_DUMMY = 64, SPICOMMON_BUSFLAG_MASTER = 1, SPICOMMON_BUSFLAG_IOMUX_PINS = 2 };
typedef void *spi_device_handle_t;
typedef struct {
    int sclk_io_num;
    union { int mosi_io_num; int data0_io_num; };
    union { int miso_io_num; int data1_io_num; };
    union { int quadwp_io_num; int data2_io_num; };
    union { int quadhd_io_num; int data3_io_num; };
    int data4_io_num, data5_io_num, data6_io_num, data7_io_num, max_transfer_sz, flags;
} spi_bus_config_t;
typedef struct {
    int clock_speed_hz, mode, spics_io_num, queue_size, flags, command_bits, address_bits;
} spi_device_interface_config_t;
typedef struct {
    uint32_t flags, cmd, addr;
    size_t length, rxlength;
    union { uint8_t tx_data[4]; const void *tx_buffer; };
    void *rx_buffer;
} spi_transaction_t;
typedef struct { spi_transaction_t base; unsigned dummy_bits; } spi_transaction_ext_t;
esp_err_t spi_bus_initialize(int host, const spi_bus_config_t *config, int dma);
esp_err_t spi_bus_add_device(int host, const spi_device_interface_config_t *config, spi_device_handle_t *device);
esp_err_t spi_bus_remove_device(spi_device_handle_t device);
esp_err_t spi_bus_free(int host);
esp_err_t spi_device_transmit(spi_device_handle_t device, spi_transaction_t *transaction);
esp_err_t spi_device_polling_transmit(spi_device_handle_t device, spi_transaction_t *transaction);
esp_err_t spi_device_get_actual_freq(spi_device_handle_t device, int *khz);
