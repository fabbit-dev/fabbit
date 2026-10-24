# make golden_vivado  или  vivado -mode batch -source tools/build_golden.tcl   (из gateware/)
set part xc7a50tfgg484-1
set out build/vivado
file mkdir $out
set video [concat common/video/video_pkg.sv [lsearch -all -inline -not [glob common/video/*.sv] *video_pkg.sv]]
read_verilog -sv [concat $video [glob common/*.sv] common/cdc/sync_bit.sv common/mem/ram_sdp.sv golden/golden_top.sv]
read_xdc {constraints/base.xdc constraints/flash.xdc constraints/esp_bus.xdc constraints/hdmi.xdc constraints/vivado_golden.xdc constraints/golden.xdc}
synth_design -top golden_top -part $part
opt_design
place_design
route_design
write_checkpoint -force $out/golden_routed.dcp
report_timing_summary -file $out/timing.rpt
report_utilization -file $out/util.rpt
report_cdc -file $out/golden.cdc.rpt
write_bitstream -force $out/golden.bit
write_cfgmem -force -format bin -interface spix1 -size 16 -loadbit "up 0x0 $out/golden.bit" -file $out/golden.bin
