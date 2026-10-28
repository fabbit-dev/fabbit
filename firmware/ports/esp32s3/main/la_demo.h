// Reserved demo outputs: never share with buttons, FPGA link, flash/PSRAM or USB.
#pragma once
#include <stdbool.h>
#include "esp_err.h"

enum {
    LA_DEMO_SQUARE_SLOW = 4,
    LA_DEMO_SQUARE_FAST = 6,
    LA_DEMO_PWM = 7,
    LA_DEMO_UART_TX = 8,
    LA_DEMO_SPI_CLK = 15,
    LA_DEMO_SPI_MOSI = 16,
    LA_DEMO_SPI_CS = 17,
    LA_DEMO_MARKER = 18,
};

// Init only reserves GPIOs as floating inputs. Start requires the running LA screen profile.
esp_err_t la_demo_init(void);
esp_err_t la_demo_start(void);
// Menu task services packets. Hardware clocks continue while the menu draws or downloads.
void la_demo_poll(void);
bool la_demo_active(void);
// Safe from another task, including the link's profile-exit callback. Never takes the bus lock.
void la_demo_stop(void);
