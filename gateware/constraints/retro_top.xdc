# Reuse existing verified board pin XDCs; this file adds only timing relationships.
# Legacy sdram.xdc assumes ONE controller's output flop directly at the pin.
# The shared owner mux invalidates that IOB packing request; not an I/O waiver.
# Timing remains reported/unconstrained until shared physical path signoff.
set_property IOB FALSE [get_ports {sdram_a[*] sdram_ba[*] sdram_ras_n sdram_cas_n sdram_we_n}]
# CDC constraints are deliberately endpoint-scoped. Never false-path all
# ASYNC_REG cells: that also hides stage-1 -> stage-2 timing and FIFO Gray buses.
# Read after synthesis and clock creation. Unexpected/empty selections are fatal;
# rebuilt hierarchy or optimization changes require review, not a silent waiver.
proc retro_cdc_count {objects minimum maximum description} {
    set count [llength $objects]
    if {$count < $minimum || $count > $maximum} {
        error "retro CDC: $description: expected $minimum..$maximum objects, got $count"
    }
    return $objects
}
proc retro_cdc_escape {name} {
    regsub -all {[][\\.^$*+?(){}|]} $name {\\&} escaped
    return $escaped
}
proc retro_cdc_regs {instance stem minimum maximum} {
    set pattern [format {^%s/%s_reg(\[[0-9]+\])?$} \
        [retro_cdc_escape $instance] [retro_cdc_escape $stem]]
    set cells [get_cells -quiet -hierarchical -regexp $pattern]
    return [retro_cdc_count $cells $minimum $maximum "$instance/$stem registers"]
}
proc retro_cdc_pins {cells pin} {
    set pins [get_pins -quiet -of_objects $cells -filter "REF_PIN_NAME == $pin"]
    return [retro_cdc_count $pins [llength $cells] [llength $cells] "$pin pins"]
}
proc retro_cdc_period {cells description} {
    # Use actual register C pins, not nominal/rounded MMCM frequencies. Reject
    # mixed or missing clocks rather than selecting an arbitrary clock object.
    set clocks [get_clocks -quiet -of_objects [retro_cdc_pins $cells C]]
    retro_cdc_count $clocks 1 1 "$description clock"
    set period [get_property PERIOD $clocks]
    if {![string is double -strict $period] || $period <= 0} {
        error "retro CDC: invalid period '$period' for $description"
    }
    return $period
}
proc retro_cdc_bundle {instance source capture width {launch_instance ""}} {
    # Constants, duplicate bits and unused fields can disappear during synthesis;
    # require nonempty endpoints within RTL width, and exactly one Q/D per flop.
    if {$launch_instance eq ""} {set launch_instance $instance}
    set src [retro_cdc_regs $launch_instance $source 1 $width]
    set dst [retro_cdc_regs $instance $capture 1 $width]
    set period [retro_cdc_period $dst "$instance capture"]
    # C is a valid timing startpoint. Starting at Q segments the timing graph
    # in Vivado; this bound conservatively includes clock-to-Q as well as data.
    set from [retro_cdc_pins $src C]
    set to [retro_cdc_pins $dst D]
    # A shared launch register may be merged across identical RTL instances.
    # Verify that every capture bit is actually fed by the named launch bank.
    foreach capture_pin $to {
        set fanin [all_fanin -quiet -flat -startpoints_only -to $capture_pin]
        set matched 0
        foreach launch_pin $from {
            if {$launch_pin in $fanin} {set matched 1; break}
        }
        if {!$matched} {error "retro CDC: $capture_pin has no $launch_instance/$source launch"}
    }
    set_max_delay -datapath_only $period -from $from -to $to
    set_bus_skew $period -from $from -to $to
    puts "retro CDC bundle $launch_instance/$source -> $instance/$capture: [llength $src]/[llength $dst] bits, $period ns"
}

# sync_bit.sv: s[0] alone samples the asynchronous input; s[1] stays timed.
# Module identity excludes reset_sync.s and all fifo_async Gray synchronizers.
set retro_bit_syncs [get_cells -quiet -hierarchical -filter \
    {ORIG_REF_NAME == sync_bit || REF_NAME == sync_bit || REF_NAME =~ sync_bit__*}]
retro_cdc_count $retro_bit_syncs 1 256 {sync_bit instances}
set retro_owner_syncs [get_cells -quiet -hierarchical -regexp \
    {^owner_switch/g_select\[[0-3]\][/.](command_sync|ack_sync)$}]
retro_cdc_count $retro_owner_syncs 8 8 {owner command/ack sync_bit instances}
foreach retro_sync $retro_owner_syncs {
    if {$retro_sync ni $retro_bit_syncs} {
        error "retro CDC: $retro_sync is not a discovered sync_bit instance"
    }
}
puts "retro CDC sync_bit: [llength $retro_bit_syncs] first-stage D pins, including eight owner command/ack crossings"
foreach retro_sync $retro_bit_syncs {
    set retro_name [get_property NAME $retro_sync]
    set retro_stages [retro_cdc_regs $retro_name s 2 2]
    set retro_first [get_cells -quiet -hierarchical -regexp \
        [format {^%s/s_reg\[0\]$} [retro_cdc_escape $retro_name]]]
    retro_cdc_count $retro_first 1 1 "$retro_name first stage"
    foreach retro_stage $retro_stages {
        if {![get_property ASYNC_REG $retro_stage]} {
            error "retro CDC: $retro_stage lost ASYNC_REG"
        }
    }
    set_false_path -to [retro_cdc_pins $retro_first D]
}

# reset_sync asynchronously presets every stage; zeros release through four
# unconditional destination-clock edges. Recovery into those PRE pins is the
# intentional asynchronous boundary, not a functional synchronous-reset waiver.
# Keep every stage's D timing and final-stage fanout timing enabled (UG906).
set retro_reset_syncs [get_cells -quiet -hierarchical -filter \
    {ORIG_REF_NAME == reset_sync || REF_NAME == reset_sync || REF_NAME =~ reset_sync__*}]
retro_cdc_count $retro_reset_syncs 1 64 {reset_sync instances}
foreach retro_sync $retro_reset_syncs {
    set retro_name [get_property NAME $retro_sync]
    set retro_stages [retro_cdc_regs $retro_name s 4 4]
    foreach retro_stage $retro_stages {
        if {![get_property ASYNC_REG $retro_stage] ||
            [get_property REF_NAME $retro_stage] ne "FDPE"} {
            error "retro CDC: $retro_stage is not an asynchronous-preset synchronizer"
        }
        set retro_ce [retro_cdc_pins $retro_stage CE]
        set retro_ce_net [get_nets -quiet -of_objects $retro_ce]
        retro_cdc_count $retro_ce_net 1 1 "$retro_stage CE net"
        set retro_ce_driver [get_cells -quiet -of_objects \
            [get_pins -quiet -leaf -of_objects $retro_ce_net -filter {DIRECTION == OUT}]]
        if {[llength $retro_ce_driver] != 1 ||
            [get_property REF_NAME $retro_ce_driver] ne "VCC"} {
            error "retro CDC: $retro_stage reset synchronizer is not unconditionally clocked"
        }
    }
    set_false_path -to [retro_cdc_pins $retro_stages PRE]
    puts "retro CDC reset $retro_name: four PRE pins only"
}

# retro_mailbox.sv holds payload until acknowledgement; received_q is the
# destination-domain capture (NOT its downstream consumer or pending flag).
foreach {retro_instance retro_width} {
    commands 160
    nes_stream 8
    host_bridge/transaction 58
    atom_transfer 40
} {
    retro_cdc_bundle $retro_instance payload received_q $retro_width
}

# cdc_word.sv: bound the held word_q -> q capture by ONE destination period.
# These are physical bounds, NOT functional CDC signoff. In particular the
# presentation_config, mode and audio paths still need proof of source stability,
# >=4 destination-cycle strobe spacing, reset/owner transitions and coherent
# consumer use. Functional proof PENDING; no CDC/report waiver is applied here.
# load_nes has constant data and an unused q: only its toggle synchronizer exists.
foreach {retro_instance retro_width} {
    status_transfer 96
    pads_md 32
    snes_config_map 5
    snes_config_memory 42
    nes_audio 32
    md_audio 32
    snes_audio 32
    video/md_mode_sync 2
    video/snes_mode_sync 1
    video/presentation_config 2
    video/audio_transfer/u_sample 33
} {
    retro_cdc_bundle $retro_instance word_q q $retro_width
}
# These three instances have identical source clock/strobe/data. Rebuilt
# synthesis merges their launch words into pads_md; captures remain separate.
retro_cdc_bundle pads_nes word_q q 32 pads_md
retro_cdc_bundle pads_snes word_q q 32 pads_md

# fifo_async.sv: Aw+1 Gray bits must reach stage 1 within the SHORTER of
# launch/capture clock periods. Neither Gray stage is false-pathed; stage 1 ->
# stage 2 retains ordinary timing. Bus skew is also bounded by that same period.
proc retro_cdc_gray_launch {instance direction bits} {
    set launch {}
    for {set bit 0} {$bit < $bits} {incr bit} {
        set pattern [format {^%s/%sgray_q_reg\[%d\]$} \
            [retro_cdc_escape $instance] $direction $bit]
        set cell [get_cells -quiet -hierarchical -regexp $pattern]
        if {![llength $cell] && $bit == $bits - 1} {
            # Gray's MSB equals binary's MSB; synthesis may merge those flops.
            set pattern [format {^%s/%sbin_reg\[%d\]$} \
                [retro_cdc_escape $instance] $direction $bit]
            set cell [get_cells -quiet -hierarchical -regexp $pattern]
        }
        retro_cdc_count $cell 1 1 "$instance $direction Gray launch bit $bit"
        set pattern [format {^%s/%sgray_s1_reg\[%d\]$} \
            [retro_cdc_escape $instance] $direction $bit]
        set capture [get_cells -quiet -hierarchical -regexp $pattern]
        retro_cdc_count $capture 1 1 "$instance $direction Gray capture bit $bit"
        set fanin [all_fanin -quiet -flat -startpoints_only \
            -to [retro_cdc_pins $capture D]]
        set clock_pin [retro_cdc_pins $cell C]
        if {[llength $fanin] != 1 || $clock_pin ni $fanin} {
            error "retro CDC: $instance $direction Gray bit $bit launch is not direct"
        }
        lappend launch {*}$cell
    }
    # Re-query a Vivado collection: building a Tcl list discards object typing.
    set patterns {}
    foreach name $launch {lappend patterns [retro_cdc_escape $name]}
    set cells [get_cells -quiet -hierarchical -regexp [format {^(%s)$} [join $patterns |]]]
    return [retro_cdc_count $cells $bits $bits "$instance $direction Gray launch"]
}
foreach {retro_instance retro_bits} {
    rom_fifo 13
    video/g_source[0].fifo 10
    video/g_source[1].fifo 10
    video/g_source[2].fifo 10
} {
    foreach retro_direction {w r} {
        set retro_src [retro_cdc_gray_launch $retro_instance $retro_direction $retro_bits]
        set retro_dst [retro_cdc_regs $retro_instance ${retro_direction}gray_s1 \
            $retro_bits $retro_bits]
        # Assert stage 2 still exists, without attaching any timing exception.
        retro_cdc_regs $retro_instance ${retro_direction}gray_s2 $retro_bits $retro_bits
        set retro_source_period [retro_cdc_period $retro_src "$retro_instance launch"]
        set retro_capture_period [retro_cdc_period $retro_dst "$retro_instance capture"]
        set retro_bound [expr {min($retro_source_period, $retro_capture_period)}]
        set retro_from [retro_cdc_pins $retro_src C]
        set retro_to [retro_cdc_pins $retro_dst D]
        set_max_delay -datapath_only $retro_bound -from $retro_from -to $retro_to
        set_bus_skew $retro_bound -from $retro_from -to $retro_to
        puts "retro CDC Gray $retro_instance $retro_direction: $retro_bits bits, $retro_bound ns"
    }
}
# Native SDRAM clock changes only with controllers reset, NOP and DQ tri-stated.
# Physically exclusive alternatives on the two dedicated glitch-free BUFGCTRLs.
# BUFH input bridges preserve these source clocks; they add no timing exception.
# The buffered-reference video MMCM is u_vclk/g_buffered_reference/u_mmcm;
# its generated clocks are inferred normally, with no clock-group waiver.
set_clock_groups -physically_exclusive \
    -group [get_clocks -of_objects [get_pins u_nesclk/u_mmcm/CLKOUT2]] \
    -group [get_clocks -of_objects [get_pins u_retroclk/u_mmcm/CLKOUT3]] \
    -group [get_clocks -of_objects [get_pins u_snesclk/mmcm/CLKOUT2]]
# Existing NES controller 1:3 schedule, preserved from nes_clocks.xdc.
set nes_clk [get_clocks -of_objects [get_pins u_nesclk/u_mmcm/CLKOUT0]]
set nes_fclk [get_clocks -of_objects [get_pins u_nesclk/u_mmcm/CLKOUT1]]
set_multicycle_path 3 -setup -end -from $nes_clk -to $nes_fclk
set_multicycle_path 2 -hold -end -from $nes_clk -to $nes_fclk
set_multicycle_path 2 -setup -start -from $nes_fclk -to $nes_clk
set_multicycle_path 1 -hold -start -from $nes_fclk -to $nes_clk
