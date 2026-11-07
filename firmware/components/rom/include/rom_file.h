// Portable, bounded file probe. Reads 512 initial bytes and SNES header candidates only.
#pragma once
#include "rom.h"
#include <stdio.h>

// Does not own/close the file; file position after the call is unspecified.
rom_result_t rom_probe_file(FILE *file, const char *path, rom_info_t *info);
bool rom_candidate(const char *path);
// Replace the final suffix, not a fixed number of characters. False on truncation.
bool rom_sidecar(const char *path, const char *suffix, char *out, size_t capacity);
