# AREA_BUDGET_UNCONNECTED_MEMORY_RETURN_PORTS_NOT_FUNCTIONAL_PROFILE
# Portable OOC resource gate; no route, bitstream, functional or timing signoff.
# Invocation: vivado -mode batch -source gateware/tools/synth_retro_budget.tcl
# Optional -tclargs <output-directory>; default gateware/build/retro/budget.
# Core memories stay runtime input ports. No blackbox/subset/constant-return waiver.
# NES cart internal tri0/tri1 conversion warnings remain visible baseline warnings.
set root [file normalize [file join [file dirname [info script]] ../..]]
set gate [file join $root gateware]
set out [file join $gate build retro budget]
if {[llength $argv]} {set out [file normalize [lindex $argv 0]]}
file mkdir $out
set nes [file join $gate profiles nes core src]
set src [list [file join $nes t65 T65_Pack.v]]
foreach name {t65/T65_ALU.v t65/T65_MCode.v t65/T65.v apu.v cart.sv dpram.v EEPROM_24C0x.sv
              nes.v ppu.v mappers/generic.sv mappers/iir_filter.v mappers/JYCompany.sv mappers/misc.sv
              mappers/MMC1.sv mappers/MMC2.sv mappers/MMC3.sv mappers/MMC5.sv mappers/Namco.sv
              mappers/Sachen.sv mappers/Sunsoft.sv mappers/FDS.sv mappers/VRC.sv sdram_nes.v} {
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
foreach name {
    common/video/video_pkg.sv profiles/nes/nes_palette_pkg.sv common/mem/ram_sdp.sv
    common/cdc/sync_bit.sv common/cdc/reset_sync.sv common/cdc/fifo_async.sv
    common/qspi_slave.sv common/icap_ctrl.sv common/profile_shell.sv common/profile_bus.sv
    profiles/nes/nes_config_pkg.sv profiles/nes/nes_clocks.sv profiles/nes/nes_sdram.sv
    common/video/video_clocks.sv common/video/video_timing.sv common/video/tmds_encoder.sv
    common/video/tmds_phy_se.sv common/video/hdmi_tx.sv
    profiles/retro/retro_control.sv profiles/retro/retro_rom_writer.sv
    profiles/retro/retro_loader.sv profiles/retro/retro_mem_mux.sv
    profiles/retro/retro_mem_lanes.sv profiles/retro/retro_sdram.sv
    profiles/retro/retro_clocks.sv profiles/retro/retro_pixels.sv profiles/retro/retro_framebuffer.sv
    profiles/retro/md/retro_md_memory.sv sim/retro_area.sv sim/retro_budget.sv
} {
    lappend src [file join $gate $name]
}
# Package is required before nes_sdram; read explicitly before the list as well.
set config [file join $gate profiles nes nes_config_pkg.sv]
set src [linsert [lsearch -all -inline -not -exact $src $config] 0 $config]
set unique {}
foreach file $src {if {$file ni $unique} {lappend unique $file}}
set src $unique
foreach name {microrom nanorom} {
    file copy -force [file join $gate profiles retro md rtl fx68k $name.mem] [file join $out $name.mem]
}
set manifest [open [file join $out budget.sources.txt] w]
foreach file $src {puts $manifest [string range $file [expr {[string length $root]+1}] end]}
close $manifest
cd $out
set_property include_dirs [list [file join $gate profiles retro md rtl vdp] \
    [file join $gate profiles retro snes rtl] [file join $gate profiles retro snes rtl spc700]] \
    [current_fileset]
read_verilog -sv $src
synth_design -top retro_budget -part xc7a50tfgg484-1 -mode out_of_context -flatten_hierarchy none
create_clock -name board -period 40.0 [get_ports clk_25m]
create_clock -name snes_memory_external -period 11.64021 [get_ports mem_fast_clk]
set bad [get_cells -hierarchical -filter {IS_BLACKBOX == 1}]
if {[llength $bad]} {error "Unexpected blackboxes: $bad"}
foreach instance {cores cores/nes cores/md cores/snes snes_backend nes_backend md_adapter
                  ownership lanes generic_backend loader stream_fifo shared_framebuffer
                  nes_pixels_fifo md_pixels_fifo snes_pixels_fifo display bus
                  console_clocks nes_clocking video_clocking} {
    if {![llength [get_cells -quiet $instance]]} {error "Essential instance missing: $instance"}
}
report_utilization -file [file join $out budget.util.rpt]
report_utilization -hierarchical -hierarchical_depth 8 -file [file join $out budget.hierarchy.rpt]
# Primitive-count budget is a transparent secondary view; report_utilization's
# adjusted Slice LUT count remains authoritative for the LUT6 budget.
set counters [open [file join $out budget.primitive-counts.txt] w]
foreach ref {LUT1 LUT2 LUT3 LUT4 LUT5 LUT6 LUT6_2 RAMB36E1 RAMB18E1 DSP48E1
             MMCME2_ADV MMCME2_BASE PLLE2_ADV PLLE2_BASE BUFG ICAPE2 ODDR IOBUF} {
    puts $counters "$ref [llength [get_cells -quiet -hierarchical -filter [format {REF_NAME == %s} $ref]]]"
}
close $counters
report_clocks -file [file join $out budget.clocks.rpt]
report_timing_summary -file [file join $out budget.timing.rpt]
write_checkpoint -force [file join $out budget.dcp]
puts "AREA_BUDGET_UNCONNECTED_MEMORY_RETURN_PORTS_NOT_FUNCTIONAL_PROFILE"
puts "No P&R or bitstream. Missing bridges/audio/handover/CSR decoder/SNES-memory PLL unbudgeted."
