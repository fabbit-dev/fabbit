#pragma once
#include "FreeRTOS.h"
typedef void *TaskHandle_t;
#define pdPASS 1
void vTaskDelay(TickType_t ticks);
void vTaskDelete(TaskHandle_t task);
int xTaskCreatePinnedToCore(void (*task)(void *), const char *name, uint32_t stack,
                          void *arg, unsigned priority, TaskHandle_t *handle, int core);
