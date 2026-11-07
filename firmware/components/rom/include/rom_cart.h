// Cartridge metadata for the initial MD/SNES subset, independent of backend availability.
#pragma once
#include "rom.h"

typedef enum { ROM_CART_OK, ROM_CART_INVALID, ROM_CART_UNSUPPORTED, ROM_CART_AMBIGUOUS } rom_cart_result_t;
typedef enum { ROM_SNES_LOROM, ROM_SNES_HIROM } rom_snes_map_t;
typedef struct {
    size_t payload_offset, payload_size;
    uint32_t reset_pc;
    bool sram;
    uint32_t ram_size;
} rom_md_info_t;
typedef struct {
    size_t payload_offset, payload_size;
    rom_snes_map_t map;
    bool fast_rom;
    uint8_t cart_type, region;
    uint32_t ram_size;
    uint8_t header[64];  // canonical internal header, NOT the optional 512-byte prefix
} rom_snes_info_t;

// Raw big-endian linear MD cartridges <=4 MiB. No SMD deinterleave or byte swapping.
// Requires explicit 'U' in the region field. Validates vectors/header/range,
// rejects known SVP/32X/Pico and serial EEPROM headers. Not a game-specific
// SRAM header ranges are limited to the implemented 0x200000..0x21ffff aperture.
// compatibility database; CD, lock-on peripherals and non-linear mappers are
// not implemented. Numeric/JP/EU-only region fields are not supported.
rom_cart_result_t rom_parse_md(const uint8_t *header, size_t header_size, uint64_t file_size,
                              rom_md_info_t *info);
// Caller reads candidate 64-byte headers at prefix+0x7fc0 and prefix+0xffc0.
// Missing candidates may be NULL. file_size%32768 must be 0 or 512 (copier prefix).
// Plain power-of-two LoROM/HiROM only, NTSC JP/US, no cartridge coprocessors;
// non-power-of-two dumps need a future mirroring pass. No content checksum test.
rom_cart_result_t rom_parse_snes(const uint8_t *lo, size_t lo_size,
                                const uint8_t *hi, size_t hi_size,
                                uint64_t file_size, rom_snes_info_t *info);
