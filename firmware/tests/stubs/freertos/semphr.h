#pragma once
#include "FreeRTOS.h"
typedef void *SemaphoreHandle_t;
SemaphoreHandle_t xSemaphoreCreateMutex(void);
int xSemaphoreTake(SemaphoreHandle_t mutex, TickType_t wait);
int xSemaphoreGive(SemaphoreHandle_t mutex);
SemaphoreHandle_t xSemaphoreCreateRecursiveMutex(void);
int xSemaphoreTakeRecursive(SemaphoreHandle_t mutex, TickType_t wait);
int xSemaphoreGiveRecursive(SemaphoreHandle_t mutex);
