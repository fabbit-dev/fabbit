# Сборка openXC7 напрямую (как apio build), несколько top.  make <цель>  ->  build/<цель>.bit
# Golden с ICAP собирается в Vivado: make golden_vivado  ->  build/vivado/golden.bin
# Vivado для любой цели: make viv_<цель>  ->  build/vivado/<цель>.bit (дробный MMCM, ICAP)
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:
APIO    := $(HOME)/.apio/packages
YOSYS   := $(APIO)/oss-cad-suite/bin/yosys
NEXTPNR := $(APIO)/openxc7/bin/nextpnr-xilinx
F2F     := $(APIO)/openxc7/bin/fasm2frames
FR2BIT  := $(APIO)/openxc7/bin/xc7frames2bit
DB      := $(APIO)/openxc7/share/nextpnr/external/prjxray-db/artix7
PART    := xc7a50tfgg484-1
CHIPDB  := $(APIO)/openxc7/chipdb/xc7a50tfgg484.bin
COMMON  := $(wildcard common/*.sv) common/cdc/reset_sync.sv
# видеотракт: пакет первым, остальное после
NES_DIR := profiles/nes
VIDEO   := common/video/video_pkg.sv $(filter-out common/video/video_pkg.sv,$(wildcard common/video/*.sv))
# ядро NESTang (подмодуль): пакет и контроллер SDRAM первыми, T65_Pack до T65
NES_CORE_DIR := $(NES_DIR)/core/src
NES_CORE := $(NES_DIR)/nes_config_pkg.sv $(NES_CORE_DIR)/sdram_nes.v \
            $(addprefix $(NES_CORE_DIR)/,t65/T65_Pack.v t65/T65_ALU.v t65/T65_MCode.v t65/T65.v apu.v \
              cart.sv dpram.v EEPROM_24C0x.sv nes.v ppu.v game_loader.v mappers/generic.sv \
              mappers/iir_filter.v mappers/JYCompany.sv mappers/misc.sv mappers/MMC1.sv mappers/MMC2.sv \
              mappers/MMC3.sv mappers/MMC5.sv mappers/Namco.sv mappers/Sachen.sv mappers/Sunsoft.sv \
              mappers/FDS.sv mappers/VRC.sv)

PNR_FLAGS ?= --seed 1

wiretest_p3_SRC  := diag/wiretest_p3.sv
wiretest_p3_XDC  := constraints/base.xdc constraints/p3_all.xdc

# профили: общий верх с параметрами (chparam)
PROFILE_XDC      := constraints/base.xdc constraints/esp_bus.xdc
blink_a_SRC      := profiles/blink_top.sv
blink_a_XDC      := $(PROFILE_XDC)
blink_a_TOP      := blink_top
blink_a_PARAMS   := -set ProfileId 1 -set Pattern 0
blink_b_SRC      := profiles/blink_top.sv
blink_b_XDC      := $(PROFILE_XDC)
blink_b_TOP      := blink_top
blink_b_PARAMS   := -set ProfileId 2 -set Pattern 1

# HDMI: прозвонка ножек и тестовые картинки (openXC7: целый MMCM, 25,000 МГц)
wiretest_hdmi_SRC := diag/wiretest_hdmi.sv
wiretest_hdmi_XDC := constraints/base.xdc constraints/clk25.xdc constraints/hdmi.xdc
hdmi_bars_SRC    := $(VIDEO) common/mem/ram_sdp.sv diag/hdmi_bars.sv
hdmi_bars_XDC    := constraints/base.xdc constraints/clk25.xdc constraints/hdmi.xdc
hdmi_bars_SLANG  := 1
hdmi_bars_GEN    := Frac=0
# Vivado: hdmi_bars с дробным MMCM, 25,1875 МГц
hdmi_bars_VIVPARAMS := Frac=1

# SDRAM на 64,3 МГц: «глаз» по фазе MMCM (Vivado: make viv_sdram_eye). Файлы ядра первыми:
# наш `default_nettype none` не должен действовать на них
sdram_eye_SRC := $(NES_DIR)/nes_config_pkg.sv $(NES_DIR)/core/src/sdram_nes.v \
                 common/cdc/sync_bit.sv common/cdc/reset_sync.sv common/qspi_slave.sv common/icap_ctrl.sv \
                 common/profile_shell.sv common/profile_bus.sv $(NES_DIR)/nes_clocks.sv \
                 $(NES_DIR)/nes_sdram.sv $(NES_DIR)/sdram_tester.sv diag/sdram_eye.sv
sdram_eye_DEFS := NANO
sdram_eye_XDC := constraints/base.xdc constraints/clk25.xdc constraints/esp_bus.xdc constraints/sdram.xdc \
                 constraints/nes_clocks.xdc

# профиль NES (Vivado: make viv_nes_top): ядро первыми, затем оболочка, видео и верх
nes_top_SRC := $(NES_CORE) $(VIDEO) common/mem/ram_sdp.sv common/cdc/sync_bit.sv common/cdc/reset_sync.sv \
               common/cdc/fifo_async.sv common/cdc/cdc_word.sv common/qspi_slave.sv common/icap_ctrl.sv \
               common/profile_shell.sv common/profile_bus.sv $(NES_DIR)/nes_clocks.sv $(NES_DIR)/nes_pad.sv \
               $(NES_DIR)/nes_palette_pkg.sv $(NES_DIR)/nes_palette.sv $(NES_DIR)/nes_sdram.sv \
               $(NES_DIR)/nes_system.sv $(NES_DIR)/nes_top.sv
nes_top_DEFS := NANO
nes_top_XDC := constraints/base.xdc constraints/clk25.xdc constraints/esp_bus.xdc constraints/hdmi.xdc \
               constraints/sdram.xdc constraints/nes_clocks.xdc constraints/nes_top.xdc \
               constraints/vivado_profile.xdc

TARGETS := wiretest_p3 blink_a blink_b wiretest_hdmi hdmi_bars
all: $(addprefix build/,$(addsuffix .bit,$(TARGETS)))
$(TARGETS): %: build/%.bit
# Golden использует ICAP и дробный видеотакт: openXC7-цель не должна выдавать нерабочий образ.
golden_top: golden_vivado

.SECONDEXPANSION:
# <цель>_SLANG = 1: фронтенд yosys-slang (полный SystemVerilog: пакеты, структуры, '{...}), как у
# ядер ретро-профилей; параметры верха тогда <цель>_GEN := P=V. Примитивы Xilinx: tools/xilinx_bb.sv
build/%.json: $$($$*_SRC) $(COMMON) | build
	$(if $($*_SLANG),\
	$(YOSYS) -q -m slang -l build/$*.yosys.log -p "read_slang --empty-blackboxes tools/xilinx_bb.sv $($*_SRC) --top $(or $($*_TOP),$*) $(addprefix -G ,$($*_GEN)); synth_xilinx -arch xc7 -top $(or $($*_TOP),$*); write_json $@",\
	$(YOSYS) -q -l build/$*.yosys.log -p "read_verilog -sv $($*_SRC) $(COMMON); $(if $($*_PARAMS),chparam $($*_PARAMS) $(or $($*_TOP),$*);) synth_xilinx -arch xc7 -top $(or $($*_TOP),$*); write_json $@")

build/%.xdc: $$($$*_XDC) | build
	cat $^ > $@

build/%.fasm: build/%.json build/%.xdc
	$(NEXTPNR) -q $(PNR_FLAGS) --chipdb $(CHIPDB) --xdc build/$*.xdc --json $< --fasm $@ --report build/$*.pnr.json -l build/$*.pnr.log

build/%.frames: build/%.fasm
	$(F2F) --part $(PART) --db-root $(DB) $< > $@

build/%.bit: build/%.frames
	$(FR2BIT) --part_file $(DB)/$(PART)/part.yaml --part_name $(PART) --frm_file $< --output_file $@

build:
	mkdir -p build

SIM_COMMON := sim/xilinx_stubs.sv sim/flash_model.sv
SIM_GOLDEN := common/qspi_slave.sv common/golden_core.sv common/flash_engine.sv \
              common/spi_flash_phy.sv common/icap_ctrl.sv
sim: | build
	iverilog -g2012 -s tb_golden -o build/tb_golden.vvp sim/tb_golden.sv $(SIM_COMMON) $(SIM_GOLDEN) > build/tb_golden.log 2>&1 || { cat build/tb_golden.log; exit 1; }
	vvp -n build/tb_golden.vvp | grep -E '^(ok|FAIL|ВСЁ|ОШИБОК|TIMEOUT)'

golden_vivado: | build
	vivado -mode batch -nojournal -log build/vivado.log -source tools/build_golden.tcl

viv_%: $$($$*_SRC) | build
	vivado -mode batch -nojournal -log build/vivado_$*.log -source tools/build_vivado.tcl \
	  -tclargs $(or $($*_TOP),$*) "$($*_SRC)" "$($*_XDC)" "$($*_VIVPARAMS)" "$($*_DEFS)"

# память NES: sdram_nes + тестер против модели SDRAM, в окне фазы и вне его
NES_MEM := common/cdc/sync_bit.sv $(NES_DIR)/nes_config_pkg.sv $(NES_DIR)/core/src/sdram_nes.v \
           $(NES_DIR)/nes_sdram.sv $(NES_DIR)/sdram_tester.sv
sim_sdram: | build
	verilator --binary --timing --timescale 1ns/1ps -Wno-fatal -Wno-lint -Wno-style --top-module tb_sdram \
	  -Mdir build/tb_sdram sim/xilinx_stubs.sv $(NES_MEM) sim/sdram_model.sv sim/tb_sdram.sv > build/tb_sdram.log 2>&1
	build/tb_sdram/Vtb_sdram +expect=ok | grep -E '^(ok|FAIL|  )'
	build/tb_sdram/Vtb_sdram +expect=fail +phase_ps=6000 | grep -E '^(ok|FAIL|ВСЁ|ОШИБОК)'

# система NES на модели SDRAM: ROM через загрузчик, кадры, картинка в build/tb_nes.ppm
NES_ROM ?= $(NES_CORE_DIR)/roms/nes15.hex
NES_FRAMES ?= 4
sim_nes: | build
	verilator --binary --timing --timescale 1ns/1ps -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN \
	  --top-module tb_nes -Mdir build/tb_nes -I$(NES_CORE_DIR) $(NES_CORE) sim/xilinx_stubs.sv \
	  common/cdc/sync_bit.sv $(NES_DIR)/nes_palette_pkg.sv $(NES_DIR)/nes_sdram.sv $(NES_DIR)/nes_system.sv \
	  sim/sdram_model.sv sim/tb_nes.sv > build/tb_nes.log 2>&1
	build/tb_nes/Vtb_nes +rom=$(NES_ROM) +frames=$(NES_FRAMES) | grep -E '^(ok|FAIL|ВСЁ|ОШИБОК|ROM|кадр|  )'

# оболочка профиля глазами ESP: ID, CSR_W/CSR_R, STREAM
sim_shell: | build
	verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_shell -Mdir build/tb_shell \
	  common/qspi_slave.sv common/icap_ctrl.sv sim/xilinx_stubs.sv common/profile_shell.sv sim/tb_shell.sv > build/tb_shell.log 2>&1
	build/tb_shell/Vtb_shell | grep -E '^(ok|FAIL|ВСЁ|ОШИБОК|TIMEOUT)'

# кнопки: слово пада через cdc_word (шина → ядро NES), раскладка и турбо nes_pad
sim_pad: | build
	verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_pad -Mdir build/tb_pad \
	  common/cdc/sync_bit.sv common/cdc/cdc_word.sv $(NES_DIR)/nes_pad.sv sim/tb_pad.sv > build/tb_pad.log 2>&1
	build/tb_pad/Vtb_pad | grep -E '^(ok|FAIL|ВСЁ|ОШИБОК|TIMEOUT)'

# платформа: асинхронная FIFO на несвязанных тактах
CDC := common/mem/ram_sdp.sv common/cdc/sync_bit.sv common/cdc/reset_sync.sv common/cdc/fifo_async.sv
sim_cdc: | build
	verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_cdc -Mdir build/tb_cdc \
	  $(CDC) sim/tb_cdc.sv > build/tb_cdc.log 2>&1
	build/tb_cdc/Vtb_cdc | grep -E '^(ok|FAIL|ВСЁ|ОШИБОК|TIMEOUT)'

# видеотракт: Verilator (iverilog не берёт пакеты и очереди)
sim_video: | build
	verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_video -Mdir build/tb_video \
	  sim/xilinx_stubs.sv $(VIDEO) sim/tb_video.sv > build/tb_video.log 2>&1
	build/tb_video/Vtb_video | grep -E '^(ok|FAIL|ВСЁ|ОШИБОК|TIMEOUT|  )'

# плоскость меню: шина → osd_plane → кадр, сверка с эталоном, кадр в build/tb_osd.ppm
sim_osd: | build
	verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_osd -Mdir build/tb_osd \
	  sim/xilinx_stubs.sv $(VIDEO) common/cdc/sync_bit.sv common/mem/ram_sdp.sv common/qspi_slave.sv \
	  sim/tb_osd.sv > build/tb_osd.log 2>&1
	build/tb_osd/Vtb_osd | grep -E '^(ok|FAIL|ВСЁ|ОШИБОК|TIMEOUT|  )'

clean:
	rm -rf build
.PHONY: all clean sim sim_osd sim_video sim_cdc sim_pad sim_shell sim_sdram sim_nes golden_vivado golden_top $(TARGETS)
.PRECIOUS: build/%.json build/%.xdc build/%.fasm build/%.frames
