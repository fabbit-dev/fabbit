# make viv_<цель>: vivado -mode batch -source tools/build_vivado.tcl -tclargs <top> "<sv>" "<xdc>" "<P=V ...>" "<DEF ...>"
# Битстрим для загрузки в SRAM: build/vivado/<top>.bit, отчёты рядом.
lassign $argv top srcs xdcs params defs
set part xc7a50tfgg484-1
set out build/vivado
file mkdir $out
read_verilog -sv $srcs
read_xdc $xdcs
set generics {}
foreach p $params { lappend generics -generic $p }
foreach d $defs { lappend generics -verilog_define $d }
synth_design -top $top -part $part {*}$generics
if {$top eq "la_top" && [llength [get_cells {u_plane/u_show/s_reg[0]}]] != 1} {
    error "LA display synchronizer not found"
}
opt_design
place_design
route_design
report_timing_summary -file $out/$top.timing.rpt
report_utilization -file $out/$top.util.rpt
report_cdc -file $out/$top.cdc.rpt
report_io -file $out/$top.io.rpt
if {$top eq "la_top"} {
    report_clocks -file $out/$top.clocks.rpt
    report_clock_interaction -file $out/$top.clock_interaction.rpt
    report_exceptions -file $out/$top.exceptions.rpt
    report_methodology -file $out/$top.methodology.rpt
    report_drc -file $out/$top.drc.rpt
    if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]] < 0 ||
        [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]] < 0} {
        error "LA setup/hold timing failed; bitstream not generated"
    }
}
write_bitstream -force $out/$top.bit
