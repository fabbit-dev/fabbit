# Сборка openXC7 напрямую (как apio build), несколько top.  make <цель>  ->  build/<цель>.bit
# Golden с ICAP собирается в Vivado: make golden_vivado  ->  build/vivado/golden.bin
# Vivado для любой цели: make viv_<цель>  ->  build/vivado/<цель>.bit (дробный MMCM, ICAP)
APIO    := $(HOME)/.apio/packages
YOSYS   := $(APIO)/oss-cad-suite/bin/yosys
NEXTPNR := $(APIO)/openxc7/bin/nextpnr-xilinx
F2F     := $(APIO)/openxc7/bin/fasm2frames
FR2BIT  := $(APIO)/openxc7/bin/xc7frames2bit
DB      := $(APIO)/openxc7/share/nextpnr/external/prjxray-db/artix7
PART    := xc7a50tfgg484-1
CHIPDB  := $(APIO)/openxc7/chipdb/xc7a50tfgg484.bin
COMMON  := $(wildcard common/*.sv)
# видеотракт: пакет первым, остальное после
VIDEO   := common/video/video_pkg.sv $(filter-out common/video/video_pkg.sv,$(wildcard common/video/*.sv))
PNR_FLAGS ?= --seed 1

golden_top_SRC   := golden/golden_top.sv
golden_top_XDC   := constraints/base.xdc constraints/flash.xdc constraints/esp_bus.xdc

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
hdmi_bars_SRC    := $(VIDEO) diag/hdmi_bars.sv
hdmi_bars_XDC    := constraints/base.xdc constraints/clk25.xdc constraints/hdmi.xdc
hdmi_bars_SLANG  := 1
hdmi_bars_GEN    := Frac=0
# Vivado: hdmi_bars с дробным MMCM, 25,1875 МГц
hdmi_bars_VIVPARAMS := Frac=1

TARGETS := golden_top wiretest_p3 blink_a blink_b wiretest_hdmi hdmi_bars
all: $(addprefix build/,$(addsuffix .bit,$(TARGETS)))
$(TARGETS): %: build/%.bit

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
sim: | build
	iverilog -g2012 -o build/tb_golden.vvp sim/tb_golden.sv $(SIM_COMMON) $(COMMON) 2>&1 | grep -v -E 'unique|Static variable' || true
	vvp -n build/tb_golden.vvp | grep -E '^(ok|FAIL|ВСЁ|ОШИБОК|TIMEOUT)'

golden_vivado: | build
	vivado -mode batch -nojournal -log build/vivado.log -source tools/build_golden.tcl

viv_%: $$($$*_SRC) | build
	vivado -mode batch -nojournal -log build/vivado_$*.log -source tools/build_vivado.tcl \
	  -tclargs $(or $($*_TOP),$*) "$($*_SRC)" "$($*_XDC)" "$($*_VIVPARAMS)"

# видеотракт: Verilator (iverilog не берёт пакеты и очереди)
sim_video: | build
	verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_video -Mdir build/tb_video \
	  sim/xilinx_stubs.sv $(VIDEO) sim/tb_video.sv > build/tb_video.log 2>&1
	build/tb_video/Vtb_video | grep -E '^(ok|FAIL|ВСЁ|ОШИБОК|TIMEOUT|  )'

clean:
	rm -rf build
.PHONY: all clean sim sim_video golden_vivado $(TARGETS)
.PRECIOUS: build/%.json build/%.xdc build/%.fasm build/%.frames
