#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Isolated from legacy NES and other parallel simulation builds.
build=build/tb_retro_nes_render
mkdir -p "$build"
core=profiles/nes/core/src
sources=(profiles/nes/nes_config_pkg.sv "$core/sdram_nes.v")
for source in t65/T65_Pack.v t65/T65_ALU.v t65/T65_MCode.v t65/T65.v apu.v \
    cart.sv dpram.v EEPROM_24C0x.sv nes.v ppu.v game_loader.v mappers/generic.sv \
    mappers/iir_filter.v mappers/JYCompany.sv mappers/misc.sv mappers/MMC1.sv \
    mappers/MMC2.sv mappers/MMC3.sv mappers/MMC5.sv mappers/Namco.sv \
    mappers/Sachen.sv mappers/Sunsoft.sv mappers/FDS.sv mappers/VRC.sv; do
  sources+=("$core/$source")
done
sources+=(sim/xilinx_stubs.sv sim/retro_clock_models.sv common/cdc/sync_bit.sv
  profiles/retro/nes/retro_nes_sdram_core.sv profiles/nes/nes_sdram.sv
  profiles/nes/nes_system.sv sim/sdram_model.sv sim/tb_retro_nes_render.sv)
verilator --binary --timing --assert --timescale 1ns/1ps \
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN \
  --top-module tb_retro_nes_render -Mdir "$build" -I"$core" "${sources[@]}" \
  > "$build/build.log" 2>&1
if [[ ${1:-} == --regression ]]; then
  shift
  for offset in 0 1 2; do
    "$build/Vtb_retro_nes_render" "$@" "+start_offset=$offset" \
      > "$build/offset${offset}.log" 2>&1
    tail -n 7 "$build/offset${offset}.log"
  done
  for consumer in cpu dma ppu_bg ppu_sprite; do
    log="$build/negative_${consumer}.log"
    if "$build/Vtb_retro_nes_render" "$@" "+negative_consumer=$consumer" > "$log" 2>&1; then
      echo "FAIL: negative control $consumer unexpectedly passed" >&2
      exit 1
    fi
    # A crash/timeout or an unexercised checker is not a valid negative proof.
    grep -Fq "negative control: corrupting observed $consumer return only" "$log"
    grep -Fq "$consumer deadline/value:" "$log"
    echo "ok negative control $consumer detected at consumer boundary"
  done
  "$build/Vtb_retro_nes_render" "$@" +buffer_test=1 > "$build/buffer.log" 2>&1
  tail -n 7 "$build/buffer.log"
  log="$build/negative_ppu_buffer.log"
  if "$build/Vtb_retro_nes_render" "$@" +buffer_test=1 \
      +negative_consumer=ppu_buffer > "$log" 2>&1; then
    echo "FAIL: negative control ppu_buffer unexpectedly passed" >&2
    exit 1
  fi
  grep -Fq "negative control: corrupting observed ppu_buffer return only" "$log"
  grep -Fq "ppu_buffer deadline/value:" "$log"
  echo "ok negative control ppu_buffer detected at consumer boundary"
else
  "$build/Vtb_retro_nes_render" "$@" 2>&1 | tee "$build/run.log"
fi
