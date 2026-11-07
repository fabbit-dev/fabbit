# Core-only OOC synthesis. This does not build a profile or prove aggregate fit.
# make -C gateware synth_retro_md / synth_retro_snes
set core [lindex $argv 0]
if {$core ni {md snes}} {error "Expected md or snes"}
set root [file normalize [file join [file dirname [info script]] ../..]]
set gate [file join $root gateware]
set source_dir [file join $gate profiles retro $core]
set out [file join $gate build retro $core]
file mkdir $out
set fp [open [file join $source_dir sources.f] r]
set src {}
foreach line [split [read $fp] \n] {
    if {[string length [string trim $line]]} {
        lappend src [file join $root [string trim $line]]
    }
}
close $fp
cd $out
if {$core eq "md"} {
    set top retro_md_core
    set includes [list [file join $source_dir rtl vdp]]
    foreach name {microrom nanorom} {
        file copy -force [file join $source_dir rtl fx68k $name.mem] [file join $out $name.mem]
    }
} else {
    set top snes_console
    set includes [list [file join $source_dir rtl] [file join $source_dir rtl spc700]]
}
set_property include_dirs $includes [current_fileset]
read_verilog -sv $src
synth_design -top $top -part xc7a50tfgg484-1 -mode out_of_context -flatten_hierarchy none
if {$core eq "md"} {
    create_clock -name md -period 18.62434 [get_ports clk_master_i]
    create_clock -name z80 -period 37.24868 [get_ports clk_z80_i]
} else {
    create_clock -name snes -period 46.56085 [get_ports clk]
}
set bad [get_cells -hierarchical -filter {IS_BLACKBOX == 1}]
if {[llength $bad]} {error "Unexpected blackboxes: $bad"}
report_utilization -file [file join $out $top.util.rpt]
report_utilization -hierarchical -file [file join $out $top.hierarchy.rpt]
report_timing_summary -file [file join $out $top.timing.rpt]
report_drc -file [file join $out $top.drc.rpt]
write_checkpoint -force [file join $out $top.dcp]
puts "CORE_ONLY_NO_MEMORY_BACKEND_NO_PROFILE_NO_ROUTE"
