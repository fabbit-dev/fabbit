# Static profile 4; synthesis first, implementation only on explicit -tclargs route.
# -tclargs <synth|route> [all|nes|md|snes]: second argument selects the image.
# Each per-console image has its own output directory and RETRO_NO_* defines.
set root [file normalize [file join [file dirname [info script]] ../..]]
set gate [file join $root gateware]
set retro_image [expr {[llength $argv] > 1 ? [lindex $argv 1] : "all"}]
array set retro_image_systems {all 7 nes 1 md 2 snes 4}
if {![info exists retro_image_systems($retro_image)]} {
    error "Unknown retro image '$retro_image': expected all, nes, md or snes"
}
# Every image keeps the management domain (session/writer/video bus) on the MD
# clock; single-console images drive SDRAM through retro_sdram_single.
set retro_systems $retro_image_systems($retro_image)
set retro_defines {}
if {!($retro_systems & 1)} {lappend retro_defines RETRO_NO_NES}
if {!($retro_systems & 2)} {lappend retro_defines RETRO_NO_MD}
if {!($retro_systems & 4)} {lappend retro_defines RETRO_NO_SNES}
set out [file join $gate build retro [expr {$retro_image eq "all" ? "top" : $retro_image}]]
file mkdir $out
proc retro_build_status {out state} {
    set fp [open [file join $out build-status.txt] w]
    puts $fp $state
    close $fp
}
proc retro_video_floorplan {} {
    # Apply only after dead legacy clock logic has been removed by opt_design.
    set mmcm [get_cells -quiet -hierarchical -regexp \
        {^u_vclk/g_buffered_reference[/.]u_mmcm$}]
    if {[llength $mmcm] != 1 || [get_property REF_NAME $mmcm] ne "MMCME2_ADV" ||
        ![get_property IS_PRIMITIVE $mmcm]} {
        error "Retro floorplan: expected one active video MMCM, got $mmcm"
    }
    if {"COMPENSATION" in [list_property $mmcm] &&
        [get_property COMPENSATION $mmcm] ne "BUF_IN"} {
        error "Retro floorplan: video MMCM compensation changed"
    }
    set cmt_region [get_clock_regions -quiet X0Y0]
    set cmt [get_sites -quiet -of_objects $cmt_region -filter {SITE_TYPE == MMCME2_ADV}]
    if {[llength $cmt_region] != 1 || [llength $cmt] != 1 ||
        [get_property NAME $cmt] ne "MMCME2_ADV_X0Y0"} {
        error "Retro floorplan: expected reviewed X0Y0 MMCM site"
    }
    if {[get_property IS_LOC_FIXED $mmcm] && [get_property LOC $mmcm] ne $cmt} {
        error "Retro floorplan: video MMCM has conflicting fixed placement"
    }
    foreach occupant [get_cells -quiet -of_objects $cmt] {
        if {$occupant ne $mmcm && [get_property IS_LOC_FIXED $occupant]} {
            error "Retro floorplan: X0Y0 MMCM site already fixed to $occupant"
        }
    }
    # Moving the video CMT frees its reference/feedback HROW demand near SDRAM.
    # Leave output/feedback BUFG locations free for legal bottom-half placement.
    set_property LOC $cmt $mmcm
    set phy [get_cells -quiet -hierarchical -filter \
        {NAME =~ video/transmitter/u_phy/* && IS_PRIMITIVE == 1 && (REF_NAME =~ FD* || REF_NAME =~ LUT*)}]
    set x5 [get_cells -quiet -hierarchical -regexp \
        {^video/transmitter/u_phy/(sh_reg\[[0-3]\]\[[0-9]+\]|tog_5x(_d)?_reg)$}]
    if {[llength $phy] < 60 || [llength $phy] > 150 || [llength $x5] != 35} {
        error "Retro floorplan: unexpected PHY fabric/x5 count [llength $phy]/[llength $x5]"
    }
    set region [get_clock_regions -quiet X1Y0]
    set sites [get_sites -quiet -of_objects $region -filter {SITE_TYPE == SLICEL || SITE_TYPE == SLICEM}]
    if {[llength $region] != 1 || ![llength $sites]} {
        error "Retro floorplan: HDMI output region has no slice sites"
    }
    set minx 100000; set miny 100000; set maxx -1; set maxy -1
    foreach site $sites {
        if {![regexp {^SLICE_X([0-9]+)Y([0-9]+)$} $site -> x y]} {
            error "Retro floorplan: unexpected slice site $site"
        }
        set minx [expr {min($minx,$x)}]; set maxx [expr {max($maxx,$x)}]
        set miny [expr {min($miny,$y)}]; set maxy [expr {max($maxy,$y)}]
    }
    if {[llength [get_pblocks -quiet retro_tmds_fabric]]} {
        error "Retro floorplan: retro_tmds_fabric already exists"
    }
    create_pblock retro_tmds_fabric
    set block [get_pblocks retro_tmds_fabric]
    resize_pblock $block -add [format {SLICE_X%dY%d:SLICE_X%dY%d} $minx $miny $maxx $maxy]
    add_cells_to_pblock $block $phy
    # Physical optimization may move pixel-word FFs out to improve timing.
    set_property IS_SOFT TRUE $block
    puts "Retro floorplan: video MMCM $cmt; [llength $phy] PHY cells, 35 x5 FFs, soft X1Y0 Pblock"
}
# Old routed reports/checkpoints may remain after a failed attempt. This marker
# identifies whether the current source manifest actually reached those stages.
retro_build_status $out started
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
    profiles/retro/retro_sdram_owner.sv profiles/retro/retro_sdram_single.sv
    profiles/retro/retro_sdram_phy.sv
    profiles/retro/retro_sdram_io.sv
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
foreach name {base.xdc clk25.xdc esp_bus.xdc hdmi.xdc sdram.xdc retro_top.xdc vivado_profile.xdc} {
    puts $fp [exec sha256sum [file join $gate constraints $name]]
}
puts $fp [exec sha256sum [file join $gate tools build_retro.tcl]]
close $fp
foreach name {microrom nanorom} {
    file copy -force [file join $gate profiles retro md rtl fx68k $name.mem] [file join $out $name.mem]
}
set_property include_dirs [list [file join $gate profiles retro md rtl vdp] \
    [file join $gate profiles retro snes rtl] [file join $gate profiles retro snes rtl spc700]] \
    [current_fileset]
cd $out
read_verilog -sv $src
set retro_define_args {}
foreach retro_define $retro_defines {lappend retro_define_args -verilog_define $retro_define}
synth_design -top retro_top -part xc7a50tfgg484-1 -flatten_hierarchy rebuilt {*}$retro_define_args
set fp [open [file join $out image.txt] w]
puts $fp "image $retro_image systems $retro_systems defines {$retro_defines}"
close $fp
report_utilization -file [file join $out synthesis.util.rpt]
report_utilization -hierarchical -file [file join $out synthesis.hierarchy.rpt]
report_drc -file [file join $out synthesis.drc.rpt]
report_cdc -file [file join $out synthesis.cdc.rpt]
set bb [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
if {[llength $bb]} {error "Unexpected blackboxes: $bb"}
report_io -file [file join $out synthesis.io.rpt]
report_clocks -file [file join $out synthesis.clocks.rpt]
write_checkpoint -force [file join $out synthesis.dcp]
retro_build_status $out synthesized
if {[lindex $argv 0] ne "route"} {exit}
# retro_top.xdc reads retro_systems to select the present consoles' crossings.
foreach xdc {base.xdc clk25.xdc esp_bus.xdc hdmi.xdc sdram.xdc vivado_profile.xdc} {
    read_xdc [file join $gate constraints $xdc]
}
# Dynamic CDC endpoint checks use Tcl procedures and loops, which read_xdc skips.
# Execute them before optimization; empty or unexpected endpoint sets are fatal.
source [file join $gate constraints retro_top.xdc]
report_exceptions -coverage -file [file join $out synthesis.exceptions.rpt]
opt_design
retro_video_floorplan
place_design
phys_opt_design
retro_build_status $out placed
if {[catch {route_design} reason options]} {
    retro_build_status $out route_failed
    write_checkpoint -force [file join $out failed-route.dcp]
    report_route_status -file [file join $out failed-route.status.rpt]
    report_clock_utilization -file [file join $out failed-route.clocks.rpt]
    report_drc -file [file join $out failed-route.drc.rpt]
    return -options $options $reason
}
retro_build_status $out routed
report_utilization -file [file join $out routed.util.rpt]
report_timing_summary -report_unconstrained -file [file join $out routed.timing.rpt]
report_cdc -file [file join $out routed.cdc.rpt]
report_exceptions -coverage -file [file join $out routed.exceptions.rpt]
report_bus_skew -file [file join $out routed.bus-skew.rpt]
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
