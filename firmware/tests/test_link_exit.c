// Real fpga_link fl_write path: stop callback must run before every profile-changing frame.
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "freertos/semphr.h"
#include "fpga_link.h"

static int mutex_storage, lock_depth, callbacks, transfers, fail_tx;
static bool enabled;
SemaphoreHandle_t xSemaphoreCreateRecursiveMutex(void) { return &mutex_storage; }
int xSemaphoreTakeRecursive(SemaphoreHandle_t m, TickType_t ticks)
{
    assert(m==&mutex_storage); lock_depth++; return 1;
}
int xSemaphoreGiveRecursive(SemaphoreHandle_t m) { assert(lock_depth>0); lock_depth--; return 1; }
void *heap_caps_malloc(size_t n,int caps) { return malloc(n); }
esp_err_t gpio_config(const gpio_config_t *c) { assert(c->pin_bit_mask==1ULL<<5); return ESP_OK; }
esp_err_t spi_bus_initialize(int host,const spi_bus_config_t *c,int dma)
{
    assert(host==SPI2_HOST && c->sclk_io_num==12 && c->data4_io_num==-1);
    return ESP_OK;
}
esp_err_t spi_bus_add_device(int host,const spi_device_interface_config_t *c,spi_device_handle_t *dev)
{
    assert(host==SPI2_HOST && c->spics_io_num==10); *dev=&mutex_storage; return ESP_OK;
}
esp_err_t spi_device_get_actual_freq(spi_device_handle_t d,int *khz) { *khz=10000; return ESP_OK; }
esp_err_t spi_device_polling_transmit(spi_device_handle_t d,spi_transaction_t *t)
{
    assert(lock_depth>0);
    if(t->cmd==FL_CMD_BOOT || t->cmd==FL_CMD_REBOOT_GOLDEN) assert(!enabled);
    transfers++;
    return fail_tx ? ESP_ERR_TIMEOUT : ESP_OK;
}
static void stop(void) { assert(lock_depth>0); enabled=false; callbacks++; }
int main(void)
{
    assert(fl_init(10000000)==ESP_OK && !lock_depth);
    fl_set_profile_exit_hook(stop);
    enabled=true;
    uint8_t key[]={'F','B','K','Y'};
    assert(fl_write(FL_CMD_CSR_W,1,key,4)==ESP_OK && enabled && !callbacks);
    int before=transfers;
    assert(fl_write(FL_CMD_BOOT,0,NULL,4)==ESP_ERR_INVALID_ARG && enabled && !callbacks && transfers==before);
    assert(fl_write(FL_CMD_BOOT,0,key,FL_BUF_SIZE+1)==ESP_ERR_INVALID_SIZE && !callbacks);
    assert(fl_boot(0x400000)==ESP_OK && !enabled && callbacks==1 && !lock_depth);
    enabled=true;
    fl_lock();
    assert(fl_reboot_golden()==ESP_OK && callbacks==2 && lock_depth==1);
    fl_unlock();
    enabled=true; fail_tx=1;
    assert(fl_write(FL_CMD_REBOOT_GOLDEN,0,key,4)==ESP_ERR_TIMEOUT && callbacks==3 && !enabled && !lock_depth);
    fail_tx=0;
    fl_set_profile_exit_hook(NULL);
    assert(fl_boot(0x400000)==ESP_OK && callbacks==3 && !lock_depth);
    puts("PASS link: BOOT/REBOOT stop hook before SPI, recursive lock, invalid args, transmit failure");
}
