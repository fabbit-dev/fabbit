#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "ui.h"

void pcsim_shot(const char *name);
void pcsim_check(bool ok, const char *what);
void pcsim_plane_clear(void);
void pcsim_app(uint8_t *fb, const ui_port_t *ui);
