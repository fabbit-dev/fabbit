# Run the installed AMD SecureIP ISERDESE2 model; vendor RTL is never copied into this project.
# Vivado: -mode batch -source tools/sim_la_serdes.tcl -tclargs sampler|datapath|qspi|loopback
set root [pwd]
set mode [lindex $argv 0]
if {$mode ni {sampler datapath qspi loopback}} { error "Expected sampler, datapath, qspi or loopback" }
set out [file join $root build xsim_la_$mode]
file mkdir $out
cd $out
set srcs [list common/mem/ram_sdp.sv profiles/la/la_ring.sv profiles/la/la_sampler.sv \
               profiles/la/la_loopback.sv \
               profiles/la/la_system.sv]
if {$mode eq "sampler"} {
    lappend srcs sim/tb_la_serdes_sampler.sv
    set top tb_la_serdes_sampler
} elseif {$mode eq "qspi"} {
    lappend srcs common/qspi_slave.sv common/icap_ctrl.sv sim/xilinx_stubs.sv \
                 common/profile_shell.sv sim/tb_la_profile.sv
    set top tb_la_profile
} elseif {$mode eq "loopback"} {
    lappend srcs sim/tb_la_loopback.sv
    set top tb_la_loopback
} else {
    lappend srcs sim/tb_la_ddr.sv
    set top tb_la_ddr
}
set absolute {}
foreach src $srcs { lappend absolute [file join $root $src] }
# Some Linux simulator toolchains need an explicit system library search path for crt*.o.
# Optional: e.g. make sim_la_serdes LIBRARY_PATH=<system-library-directory>.
exec xvlog --sv {*}$absolute > compile.log 2>@1
exec xvlog [file join $env(XILINX_VIVADO) data verilog src glbl.v] >> compile.log 2>@1
set generic {}
if {$mode ne "sampler"} { set generic [list --generic_top Serdes=1] }
exec xelab work.$top work.glbl -L unisims_ver -L secureip {*}$generic \
    -s la_test --debug typical > elaborate.log 2>@1
exec xsim la_test -runall > run.log 2>@1
set file [open run.log r]
set result [read $file]
close $file
puts $result
# xsim may return status zero even for $fatal. Require the test's completion marker.
if {[string match {*Fatal:*} $result] || ![string match {*ok   *} $result] ||
    ($mode eq "qspi" && ![string match {*ALL LA OK*} $result]) ||
    ($mode eq "sampler" && ![string match {*ALL LA SAMPLER OK*} $result]) ||
    ($mode eq "loopback" && ![string match {*ALL LA LOOPBACK OK*} $result]) ||
    ($mode eq "datapath" && ![string match {*ALL LA DATAPATH OK*} $result])} {
    error "LA simulation did not pass; see $out/run.log"
}
