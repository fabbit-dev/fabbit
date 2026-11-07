// RETRO profile 4, ABI 1. NES legacy nes_rom API/wire format remains separate.
#pragma once
#include "esp_err.h"
#include "rom.h"

#define RETRO_PROFILE_ID 4
#define RETRO_MAGIC 0x46524554u
#define RETRO_KEY 0x52540000u
enum {
    RETRO_ID, RETRO_CTRL, RETRO_STAT, RETRO_FREE, RETRO_RX, RETRO_SYSTEM,
    RETRO_LENGTH, RETRO_MAP, RETRO_SIZE, RETRO_SAVE_SIZE, RETRO_ASSETS,
    RETRO_ERROR, RETRO_IPL, RETRO_COEFF, RETRO_RESERVED, RETRO_ABI, RETRO_CAPS
};
// CSR5 reads ACTIVE system, not the editable shadow; BEGIN snapshots CSR5..9.
enum {
    RETRO_BEGIN = 1, RETRO_COMMIT = 2, RETRO_ABORT = 4, RETRO_RESET = 8,
    RETRO_CLEAR_IPL = 256, RETRO_CLEAR_COEFF = 512
};
enum {
    RETRO_LOADING = 1, RETRO_RUNNING = 2, RETRO_FAILED = 4, RETRO_READY = 8,
    RETRO_DRAIN_BUSY = 16, RETRO_CMD_BUSY = 32, RETRO_PAYLOAD_DONE = 64
};

// User-provided runtime assets, never bundled or synthesized as defaults.
// IPL is exactly 64 bytes; gauss exactly 1024 bytes (512 little-endian 12-bit
// containers, each upper nibble zero). These are not cartridge ROM payloads.
#define RETRO_SNES_IPL_PATH "/data/roms/snes.ipl"
#define RETRO_SNES_GAUSS_PATH "/data/roms/snes.gauss"

bool retro_present(void);
// Active RETRO image reports this console in RETRO_CAPS (per-console images).
bool retro_supports(rom_system_t system);
// Local preflight only; safe BEFORE pm_load/programming/any FPGA access.
esp_err_t retro_preflight(const char *path, rom_info_t *info);
// Requires active RETRO. Bounded heap chunk, recursive bus lock, abort/drain on failure.
esp_err_t retro_load_file(const char *path, void (*progress)(void *, int), void *ctx, uint32_t *ms);
esp_err_t retro_reset(void);
// Quiesce and drain before leaving the profile; no BOOT or flash access here.
esp_err_t retro_stop(void);
