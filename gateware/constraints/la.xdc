# i9+ on i5/i9 ext-board: D0..D15 on P2 pins 4,5,6,7,9,12,13,15,17,18,19,22,24,25,26,28.
# Source: wuxx Colorlight-FPGA-Projects/colorlight_i9plus_v6.1.md, SO-DIMM table;
# ext-board mapping checked against i5-i9-extboard schematic. All inputs bank 34, LVCMOS33.
set_property -dict {PACKAGE_PIN U2 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {probe[0]}]
set_property -dict {PACKAGE_PIN V2 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {probe[1]}]
set_property -dict {PACKAGE_PIN W1 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {probe[2]}]
set_property -dict {PACKAGE_PIN AA1 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {probe[3]}]
set_property -dict {PACKAGE_PIN W2 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {probe[4]}]
set_property -dict {PACKAGE_PIN AB2 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {probe[5]}]
set_property -dict {PACKAGE_PIN AB3 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {probe[6]}]
set_property -dict {PACKAGE_PIN Y6 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {probe[7]}]
set_property -dict {PACKAGE_PIN Y3 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {probe[8]}]
set_property -dict {PACKAGE_PIN AA3 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {probe[9]}]
set_property -dict {PACKAGE_PIN Y2 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {probe[10]}]
set_property -dict {PACKAGE_PIN AB1 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {probe[11]}]
set_property -dict {PACKAGE_PIN Y1 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {probe[12]}]
set_property -dict {PACKAGE_PIN V3 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {probe[13]}]
set_property -dict {PACKAGE_PIN U3 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {probe[14]}]
set_property -dict {PACKAGE_PIN R2 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {probe[15]}]
set_property -dict {PACKAGE_PIN H2 IOSTANDARD LVCMOS33} [get_ports phy_reset_n]
# Optional loopback source: P6 contacts 3,4,5,6,7,9,12,22, all bank 35 (3.3 V).
# SOURCE: i9+ SO-DIMM table + i5/i9 ext-board schematic. These are not power pins.
# Minimum LVCMOS33 drive and slow slew reduce edge aggressiveness; not short-circuit protection.
set_property -dict {PACKAGE_PIN L4 IOSTANDARD LVCMOS33 DRIVE 4 SLEW SLOW} [get_ports {test_out[0]}]
set_property -dict {PACKAGE_PIN G4 IOSTANDARD LVCMOS33 DRIVE 4 SLEW SLOW} [get_ports {test_out[1]}]
set_property -dict {PACKAGE_PIN G3 IOSTANDARD LVCMOS33 DRIVE 4 SLEW SLOW} [get_ports {test_out[2]}]
set_property -dict {PACKAGE_PIN K2 IOSTANDARD LVCMOS33 DRIVE 4 SLEW SLOW} [get_ports {test_out[3]}]
set_property -dict {PACKAGE_PIN M1 IOSTANDARD LVCMOS33 DRIVE 4 SLEW SLOW} [get_ports {test_out[4]}]
set_property -dict {PACKAGE_PIN K1 IOSTANDARD LVCMOS33 DRIVE 4 SLEW SLOW} [get_ports {test_out[5]}]
set_property -dict {PACKAGE_PIN H3 IOSTANDARD LVCMOS33 DRIVE 4 SLEW SLOW} [get_ports {test_out[6]}]
set_property -dict {PACKAGE_PIN J1 IOSTANDARD LVCMOS33 DRIVE 4 SLEW SLOW} [get_ports {test_out[7]}]
# Timing mode intentionally samples asynchronous signals. Only the pad -> first IOB FF
# path is excepted; settling, trigger and memory paths remain timed by the generated clock.
set_false_path -from [get_ports {probe[*]}] -to [get_cells -hier -filter {NAME =~ *probe_iob_reg* || REF_NAME == IDDR || REF_NAME == ISERDESE2}]
