# Synthesis-only resource gate, not a loadable FPGA image or routed timing proof.
# make -C gateware synth_retro_shared
set root [file normalize [file join [file dirname [info script]] ../..]]
set gate [file join $root gateware]
set out [file join $gate build retro]
file mkdir $out
set shared {retro_control retro_rom_writer retro_loader retro_mem_mux retro_mem_lanes
            retro_sdram retro_sdram_io retro_clocks retro_framebuffer}
read_verilog -sv [file join $gate common video video_pkg.sv]
read_verilog -sv [file join $gate common mem ram_sdp.sv]
foreach name $shared {
    read_verilog -sv [file join $gate profiles retro $name.sv]
}
foreach top {retro_clocks retro_sdram retro_loader retro_framebuffer} {
    synth_design -top $top -part xc7a50tfgg484-1 -mode out_of_context
    if {$top eq "retro_clocks"} {
        create_clock -period 40.0 [get_ports clk_25m]
        report_clocks -file [file join $out $top.clocks.rpt]
    }
    set bad [get_cells -hierarchical -filter {IS_BLACKBOX == 1}]
    if {[llength $bad]} {error "Unexpected blackboxes: $bad"}
    report_utilization -file [file join $out $top.util.rpt]
    report_utilization -hierarchical -file [file join $out $top.hierarchy.rpt]
    write_checkpoint -force [file join $out $top.dcp]
    close_design
}
