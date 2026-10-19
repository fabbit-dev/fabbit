# Сборка openXC7 напрямую (как apio build), несколько top.  make <цель>  ->  build/<цель>.bit
# Golden с ICAP собирается в Vivado: make golden_vivado  ->  build/vivado/golden.bin
APIO    := $(HOME)/.apio/packages
YOSYS   := $(APIO)/oss-cad-suite/bin/yosys
NEXTPNR := $(APIO)/openxc7/bin/nextpnr-xilinx
F2F     := $(APIO)/openxc7/bin/fasm2frames
FR2BIT  := $(APIO)/openxc7/bin/xc7frames2bit
DB      := $(APIO)/openxc7/share/nextpnr/external/prjxray-db/artix7
PART    := xc7a50tfgg484-1
CHIPDB  := $(APIO)/openxc7/chipdb/xc7a50tfgg484.bin
COMMON  := $(wildcard common/*.sv)
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

TARGETS := golden_top wiretest_p3 blink_a blink_b
all: $(addprefix build/,$(addsuffix .bit,$(TARGETS)))
$(TARGETS): %: build/%.bit

.SECONDEXPANSION:
build/%.json: $$($$*_SRC) $(COMMON) | build
	$(YOSYS) -q -l build/$*.yosys.log -p "read_verilog -sv $($*_SRC) $(COMMON); $(if $($*_PARAMS),chparam $($*_PARAMS) $(or $($*_TOP),$*);) synth_xilinx -arch xc7 -top $(or $($*_TOP),$*); write_json $@"

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

clean:
	rm -rf build
.PHONY: all clean sim golden_vivado $(TARGETS)
.PRECIOUS: build/%.json build/%.xdc build/%.fasm build/%.frames
