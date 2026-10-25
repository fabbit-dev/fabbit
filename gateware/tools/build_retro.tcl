# Static profile 4; synthesis first, implementation only on explicit -tclargs route.
set root [file normalize [file join [file dirname [info script]] ../..]]
set gate [file join $root gateware]
set out [file join $gate build retro top]
file mkdir $out
set src [list [file join $gate profiles nes nes_config_pkg.sv]]
set nes [file join $gate profiles nes core src]
foreach name {t65/T65_Pack.v t65/T65_ALU.v t65/T65_MCode.v t65/T65.v apu.v cart.sv
    dpram.v EEPROM_24C0x.sv nes.v ppu.v game_loader.v sdram_nes.v mappers/generic.sv
    mappers/iir_filter.v mappers/JYCompany.sv mappers/misc.sv mappers/MMC1.sv mappers/MMC2.sv
    mappers/MMC3.sv mappers/MMC5.sv mappers/Namco.sv mappers/Sachen.sv mappers/Sunsoft.sv
    mappers/FDS.sv mappers/VRC.sv} {lappend src [file join $nes $name]}
foreach core {md snes} {
    set fp [open [file join $gate profiles retro $core sources.f] r]
    foreach line [split [read $fp] \n] {
        if {[string length [string trim $line]]} {lappend src [file join $root [string trim $line]]}
    }
    close $fp
}
foreach name {profiles/retro/retro_regs_pkg.sv common/video/video_pkg.sv
    profiles/nes/nes_palette_pkg.sv common/mem/ram_sdp.sv common/cdc/reset_sync.sv common/cdc/sync_bit.sv
    common/cdc/cdc_word.sv common/cdc/fifo_async.sv common/qspi_slave.sv common/icap_ctrl.sv
    common/profile_shell.sv common/profile_bus.sv common/video/video_clocks.sv
    common/video/video_timing.sv common/video/tmds_encoder.sv common/video/tmds_phy_se.sv
    common/video/hdmi_tx.sv profiles/retro/audio/retro_audio_cdc.sv
    profiles/retro/audio/retro_hdmi_packet.sv profiles/retro/audio/retro_hdmi_audio_tx.sv
    profiles/nes/nes_clocks.sv profiles/nes/nes_sdram.sv
    profiles/nes/nes_system.sv profiles/nes/nes_pad.sv profiles/retro/nes/retro_nes_sdram_core.sv
    profiles/retro/retro_clocks.sv profiles/retro/retro_snes_clocks.sv
    profiles/retro/retro_mailbox.sv profiles/retro/retro_memory_cdc.sv
    profiles/retro/retro_registers.sv profiles/retro/retro_session.sv
    profiles/retro/retro_asset_atoms.sv profiles/retro/retro_md_machine.sv
    profiles/retro/md/retro_md_memory.sv profiles/retro/retro_mem_mux.sv
    profiles/retro/retro_mem_lanes.sv profiles/retro/retro_sdram.sv
    profiles/retro/retro_sdram_owner.sv profiles/retro/retro_sdram_io.sv
    profiles/retro/retro_pixels.sv profiles/retro/retro_framebuffer.sv
    profiles/retro/retro_rom_writer.sv profiles/retro/retro_video.sv
    profiles/retro/retro_top.sv} {lappend src [file join $gate $name]}
set unique {}
foreach p $src {if {$p ni $unique} {lappend unique $p}}
set src $unique
set fp [open [file join $out sources.f] w]
foreach p $src {puts $fp $p}
close $fp
set fp [open [file join $out source-sha256.txt] w]
foreach p $src {puts $fp [exec sha256sum $p]}
foreach p [glob -nocomplain [file join $gate profiles retro md rtl vdp *.v] \
    [file join $gate profiles retro md rtl fx68k *.mem] \
    [file join $gate profiles retro snes rtl *.vh] \
    [file join $gate profiles retro snes rtl spc700 *.vh]] {puts $fp [exec sha256sum $p]}
close $fp
foreach name {microrom nanorom} {
    file copy -force [file join $gate profiles retro md rtl fx68k $name.mem] [file join $out $name.mem]
}
set_property include_dirs [list [file join $gate profiles retro md rtl vdp] \
    [file join $gate profiles retro snes rtl] [file join $gate profiles retro snes rtl spc700]] \
    [current_fileset]
cd $out
read_verilog -sv $src
synth_design -top retro_top -part xc7a50tfgg484-1 -flatten_hierarchy rebuilt
report_utilization -file [file join $out synthesis.util.rpt]
report_utilization -hierarchical -file [file join $out synthesis.hierarchy.rpt]
report_drc -file [file join $out synthesis.drc.rpt]
report_cdc -file [file join $out synthesis.cdc.rpt]
set bb [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
if {[llength $bb]} {error "Unexpected blackboxes: $bb"}
report_io -file [file join $out synthesis.io.rpt]
report_clocks -file [file join $out synthesis.clocks.rpt]
write_checkpoint -force [file join $out synthesis.dcp]
if {[lindex $argv 0] ne "route"} {exit}
foreach xdc {base.xdc clk25.xdc esp_bus.xdc hdmi.xdc sdram.xdc retro_top.xdc vivado_profile.xdc} {
    read_xdc [file join $gate constraints $xdc]
}
opt_design
place_design
phys_opt_design
route_design
report_utilization -file [file join $out routed.util.rpt]
report_timing_summary -report_unconstrained -file [file join $out routed.timing.rpt]
report_cdc -file [file join $out routed.cdc.rpt]
report_io -file [file join $out routed.io.rpt]
report_drc -file [file join $out routed.drc.rpt]
write_checkpoint -force [file join $out routed.dcp]
# Bitstream only after explicit timing checks. DRC default fatal severities remain.
set bad [get_timing_paths -quiet -slack_lesser_than 0]
if {[llength $bad]} {error "Negative setup timing; no bitstream"}
set min_bad [get_timing_paths -quiet -delay_type min -slack_lesser_than 0]
if {[llength $min_bad]} {error "Negative hold timing; no bitstream"}
# A routed checkpoint is not electrical signoff: this port reuses legacy pin
# locations but has no measured three-owner SDRAM input/output timing yet.
# Do not publish a bitstream merely because internal STA happens to be green.
error "Physical shared-SDRAM I/O timing not signed off; routed reports only, no bitstream"
