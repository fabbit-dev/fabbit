# All three real consoles instantiated together, runtime reset selection.
# Area-only: external memory responses are ports; NO common memory/display/route proof.
# NESTang cart.sv intentionally uses internal tri0/tri1 mapper buses; Vivado
# reports Synth 8-5799 while converting them to logic. Keep these baseline
# warnings visible. This script does not waive or certify their implementation.
set root [file normalize [file join [file dirname [info script]] ../..]]
set gate [file join $root gateware]
set out [file join $gate build retro area]
file mkdir $out
set nes [file join $gate profiles nes core src]
set src [list [file join $nes t65 T65_Pack.v]]
foreach name {t65/T65_ALU.v t65/T65_MCode.v t65/T65.v apu.v cart.sv dpram.v EEPROM_24C0x.sv
              nes.v ppu.v mappers/generic.sv mappers/iir_filter.v mappers/JYCompany.sv mappers/misc.sv
              mappers/MMC1.sv mappers/MMC2.sv mappers/MMC3.sv mappers/MMC5.sv mappers/Namco.sv
              mappers/Sachen.sv mappers/Sunsoft.sv mappers/FDS.sv mappers/VRC.sv} {
    lappend src [file join $nes $name]
}
lappend src [file join $gate profiles retro retro_nes_core.sv]
foreach core {md snes} {
    set fp [open [file join $gate profiles retro $core sources.f] r]
    foreach line [split [read $fp] \n] {
        if {[string length [string trim $line]]} {lappend src [file join $root [string trim $line]]}
    }
    close $fp
}
foreach name {microrom nanorom} {
    file copy -force [file join $gate profiles retro md rtl fx68k $name.mem] [file join $out $name.mem]
}
cd $out
set_property include_dirs [list [file join $gate profiles retro md rtl vdp] \
    [file join $gate profiles retro snes rtl] [file join $gate profiles retro snes rtl spc700]] \
    [current_fileset]
read_verilog -sv $src
read_verilog -sv [file join $gate sim retro_area.sv]
synth_design -top retro_area -part xc7a50tfgg484-1 -mode out_of_context -flatten_hierarchy none
create_clock -name nes -period 46.667 [get_ports nes_clk]
create_clock -name md -period 18.62434 [get_ports md_clk]
create_clock -name z80 -period 37.24868 [get_ports z80_clk]
create_clock -name snes -period 46.56085 [get_ports snes_clk]
set bad [get_cells -hierarchical -filter {IS_BLACKBOX == 1}]
if {[llength $bad]} {error "Unexpected blackboxes: $bad"}
report_utilization -file [file join $out area.util.rpt]
report_utilization -hierarchical -hierarchical_depth 8 -file [file join $out area.hierarchy.rpt]
report_timing_summary -file [file join $out area.timing.rpt]
write_checkpoint -force [file join $out area.dcp]
puts "AREA_ONLY_NO_MEMORY_NO_DISPLAY_NO_ROUTE_NO_BITSTREAM"
