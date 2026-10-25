#pragma once
#include <stdbool.h>
#include "input.h"

// Called only by the menu task; shared link operations take the recursive bus lock.
bool la_screen_attach(void);
bool la_screen_tick(void);
void la_screen_key(const in_event_t *event);
