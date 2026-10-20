# make viv_<цель>: vivado -mode batch -source tools/build_vivado.tcl -tclargs <top> "<sv>" "<xdc>" "<P=V ...>"
# Битстрим для загрузки в SRAM: build/vivado/<top>.bit, отчёты рядом.
lassign $argv top srcs xdcs params
set part xc7a50tfgg484-1
set out build/vivado
file mkdir $out
read_verilog -sv $srcs
read_xdc $xdcs
set generics {}
foreach p $params { lappend generics -generic $p }
synth_design -top $top -part $part {*}$generics
opt_design
place_design
route_design
report_timing_summary -file $out/$top.timing.rpt
report_utilization -file $out/$top.util.rpt
write_bitstream -force $out/$top.bit
