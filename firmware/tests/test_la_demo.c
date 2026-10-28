// Real generator against peripheral/link fakes. No GPIO can be driven before explicit start.
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "driver/gpio.h"
#include "driver/ledc.h"
#include "driver/spi_master.h"
#include "driver/uart.h"
#include "freertos/semphr.h"
#include "fpga_link.h"
#include "la_capture.h"
#include "la_demo.h"

static int locks, demo_lock, call, fail_at, failure, gpio_calls;
static int directions[49], levels[49], timers[3], channels[3], uart_owned, spi_owned, device_owned;
static int packet_count, uart_count, stopped_before_reboot, initial_alloc_fail;
static bool wrong_profile, no_screen, p6_enabled;
static uint32_t pwm_duty;
static int64_t time_us;
static int mutex_storage;
static bool reserved(int p) { return p==4 || p==6 || p==7 || p==8 || (p>=15 && p<=18); }
static esp_err_t operation(void)
{
    assert(demo_lock);
    return ++call==fail_at ? ESP_FAIL : ESP_OK;
}
SemaphoreHandle_t xSemaphoreCreateMutex(void) { return initial_alloc_fail ? NULL : &mutex_storage; }
int xSemaphoreTake(SemaphoreHandle_t m,TickType_t wait)
{
    assert(m==&mutex_storage && !demo_lock); demo_lock=1; return 1;
}
int xSemaphoreGive(SemaphoreHandle_t m) { assert(m==&mutex_storage && demo_lock); demo_lock=0; return 1; }
void fl_lock(void) { assert(!demo_lock); locks++; }
void fl_unlock(void) { assert(locks); locks--; }
int64_t esp_timer_get_time(void) { return time_us; }
esp_err_t fl_id(fl_id_t *id)
{
    assert(locks && demo_lock);
    if (failure) return ESP_ERR_TIMEOUT;
    *id=(fl_id_t){.profile=wrong_profile ? 1 : LA_PROFILE_ID};
    strcpy(id->magic,"FBPR");
    return ESP_OK;
}
esp_err_t fl_csr_read(uint8_t index,uint32_t *v,size_t n)
{
    assert(locks && demo_lock && n==1);
    switch(index) {
    case 0: *v=LA_MAGIC; break;
    case 64: *v=no_screen ? 0 : 0x46424d56; break;
    case 35: *v=0x46424c47; break;
    case 32: *v=p6_enabled; break;
    default: assert(0);
    }
    return ESP_OK;
}
esp_err_t gpio_reset_pin(int p) { assert(reserved(p)); directions[p]=GPIO_MODE_INPUT; gpio_calls++; return ESP_OK; }
esp_err_t gpio_set_direction(int p,int mode)
{
    assert(reserved(p));
    if (mode==GPIO_MODE_OUTPUT) { esp_err_t e=operation(); if(e) return e; }
    directions[p]=mode; return ESP_OK;
}
esp_err_t gpio_set_pull_mode(int p,int mode) { assert(reserved(p) && mode==GPIO_FLOATING); return ESP_OK; }
esp_err_t gpio_set_level(int p,int value)
{
    assert(p==18); levels[p]=value;
    if(value) return operation();
    return ESP_OK;
}
esp_err_t ledc_timer_config(const ledc_timer_config_t *c)
{
    int i=c->timer_num; assert(i>=0 && i<3);
    if(c->deconfigure) { timers[i]=0; return ESP_OK; }
    esp_err_t e=operation(); if(e) return e;
    assert(c->duty_resolution==8 && c->clk_cfg==LEDC_USE_XTAL_CLK);
    assert(c->freq_hz==(i==0 ? 10000 : i==1 ? 100000 : 1000));
    timers[i]=1; return ESP_OK;
}
esp_err_t ledc_channel_config(const ledc_channel_config_t *c)
{
    int i=c->channel; assert(i>=0 && i<3);
    if(c->deconfigure) { channels[i]=0; return ESP_OK; }
    esp_err_t e=operation(); if(e) return e;
    assert(c->gpio_num==(i==0 ? 4 : i==1 ? 6 : 7) && c->timer_sel==i && timers[i]);
    assert(c->duty==(i==2 ? 64u : 128u));
    channels[i]=1; directions[c->gpio_num]=GPIO_MODE_OUTPUT; return ESP_OK;
}
esp_err_t ledc_timer_pause(int mode,ledc_timer_t i) { assert(timers[i]); return ESP_OK; }
esp_err_t ledc_stop(int mode,ledc_channel_t i,uint32_t idle) { assert(channels[i] && !idle); return ESP_OK; }
esp_err_t ledc_set_duty(int mode,ledc_channel_t i,uint32_t duty)
{
    esp_err_t e=operation(); if(e) return e;
    assert(i==2); pwm_duty=duty; return ESP_OK;
}
esp_err_t ledc_update_duty(int mode,ledc_channel_t i) { assert(i==2); return operation(); }
esp_err_t uart_driver_install(int port,int rx,int tx,int queue,void *handle,int flags)
{
    esp_err_t e=operation(); if(e) return e;
    assert(port==1 && rx==256 && !tx && !uart_owned); uart_owned=1; return ESP_OK;
}
esp_err_t uart_driver_delete(int port) { assert(port==1 && uart_owned); uart_owned=0; return ESP_OK; }
esp_err_t uart_param_config(int port,const uart_config_t *c)
{
    assert(port==1 && c->baud_rate==115200 && c->data_bits==8 && c->source_clk==UART_SCLK_XTAL);
    return operation();
}
esp_err_t uart_set_pin(int port,int tx,int rx,int rts,int cts)
{
    esp_err_t e=operation(); if(e) return e;
    assert(port==1 && tx==8 && rx==-1 && rts==-1 && cts==-1);
    directions[8]=GPIO_MODE_OUTPUT; return ESP_OK;
}
int uart_write_bytes(int port,const void *data,size_t size)
{
    if(operation()) return -1;
    assert(port==1 && size==8 && !memcmp(data,"FABBIT\r\n",8) && levels[18]);
    uart_count++; return (int)size;
}
esp_err_t uart_wait_tx_done(int port,TickType_t timeout) { assert(timeout==20); return operation(); }
esp_err_t spi_bus_initialize(int host,const spi_bus_config_t *c,int dma)
{
    esp_err_t e=operation(); if(e) return e;
    assert(host==SPI3_HOST && !dma && !spi_owned);
    assert(c->sclk_io_num==15 && c->mosi_io_num==16 && c->miso_io_num==-1 &&
           c->quadwp_io_num==-1 && c->quadhd_io_num==-1 && c->data4_io_num==-1 && c->data7_io_num==-1);
    spi_owned=1; directions[15]=directions[16]=GPIO_MODE_OUTPUT; return ESP_OK;
}
esp_err_t spi_bus_add_device(int host,const spi_device_interface_config_t *c,spi_device_handle_t *d)
{
    esp_err_t e=operation(); if(e) return e;
    assert(host==3 && c->spics_io_num==17 && c->mode==0 && c->clock_speed_hz==100000);
    device_owned=1; *d=&device_owned; directions[17]=GPIO_MODE_OUTPUT; return ESP_OK;
}
esp_err_t spi_bus_remove_device(spi_device_handle_t d) { assert(d==&device_owned && device_owned); device_owned=0; return ESP_OK; }
esp_err_t spi_bus_free(int host) { assert(host==3 && spi_owned && !device_owned); spi_owned=0; return ESP_OK; }
esp_err_t spi_device_transmit(spi_device_handle_t d,spi_transaction_t *p)
{
    esp_err_t e=operation(); if(e) return e;
    assert(d==&device_owned && p->flags==SPI_TRANS_USE_TXDATA && p->length==32 && levels[18]);
    assert(p->tx_data[0]==0xa5 && p->tx_data[1]==0x5a && p->tx_data[2]==(uint8_t)packet_count);
    packet_count++; return ESP_OK;
}
static void off(void)
{
    assert(!la_demo_active() && !locks && !demo_lock && !uart_owned && !spi_owned && !device_owned);
    for(int p=0;p<49;p++) if(reserved(p)) assert(directions[p]==GPIO_MODE_INPUT);
    for(int i=0;i<3;i++) assert(!timers[i] && !channels[i]);
}
int main(void)
{
    assert(la_demo_start()==ESP_ERR_INVALID_STATE);
    initial_alloc_fail=1; assert(la_demo_init()==ESP_ERR_NO_MEM);
    initial_alloc_fail=0; assert(la_demo_init()==ESP_OK);
    int resets=gpio_calls; assert(la_demo_init()==ESP_OK && gpio_calls==resets);
    off(); la_demo_poll(); assert(!call);
    wrong_profile=true; assert(la_demo_start()==ESP_ERR_NOT_FOUND); off(); wrong_profile=false;
    no_screen=true; assert(la_demo_start()==ESP_ERR_NOT_FOUND); off(); no_screen=false;
    p6_enabled=true; assert(la_demo_start()==ESP_ERR_INVALID_STATE); off(); p6_enabled=false;
    call=0; assert(la_demo_start()==ESP_OK); int setup_calls=call;
    assert(la_demo_active()); la_demo_stop(); off();
    for(int i=1;i<=setup_calls;i++) {
        call=0; fail_at=i; assert(la_demo_start()!=ESP_OK); off();
    }
    fail_at=0; call=0; packet_count=uart_count=0; assert(la_demo_start()==ESP_OK);
    int keep=call; assert(la_demo_start()==ESP_OK && call==keep);
    la_demo_poll(); assert(packet_count==1 && uart_count==1 && !levels[18]);
    time_us=10000; la_demo_poll(); assert(packet_count==1);
    time_us=20000; la_demo_poll(); assert(packet_count==2);
    time_us=500000; la_demo_poll(); assert(pwm_duty==128);
    time_us=1000000; la_demo_poll(); assert(pwm_duty==192);
    time_us=1500000; la_demo_poll(); assert(pwm_duty==128);
    time_us=2000000; la_demo_poll(); assert(pwm_duty==64);
    failure=1; la_demo_poll(); off(); failure=0;
    call=0; assert(la_demo_start()==ESP_OK);
    wrong_profile=true; la_demo_poll(); off(); wrong_profile=false;
    call=0; assert(la_demo_start()==ESP_OK);
    p6_enabled=true; la_demo_poll(); off(); p6_enabled=false;
    for(int i=1;i<=6;i++) {
        call=0; fail_at=0; packet_count=uart_count=0; assert(la_demo_start()==ESP_OK);
        call=0; fail_at=i; time_us+=600000; la_demo_poll(); off();
    }
    fail_at=0; call=0; assert(la_demo_start()==ESP_OK);
    // Exercise the callback lock ordering used by fl_write before REBOOT/BOOT.
    fl_lock(); la_demo_stop(); assert(!la_demo_active()); stopped_before_reboot++; fl_unlock(); off();
    assert(stopped_before_reboot==1);
    int stopped_calls=call;
    la_demo_poll(); la_demo_stop(); assert(call==stopped_calls); off();
    puts("PASS demo: pin reservation, explicit start, peripheral parameters, packets, rollback, loss/exit Hi-Z");
}
