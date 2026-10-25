#pragma once
#include <stddef.h>
#define MALLOC_CAP_SPIRAM 1
#define MALLOC_CAP_DMA 2
#define MALLOC_CAP_INTERNAL 4
void *heap_caps_malloc(size_t n, int caps);
