# MX25L12833F, SCK = CCLK L12 через STARTUPE2
set_property -dict { PACKAGE_PIN T19 IOSTANDARD LVCMOS33 } [get_ports flash_cs_n]
set_property -dict { PACKAGE_PIN P22 IOSTANDARD LVCMOS33 } [get_ports flash_mosi]
set_property -dict { PACKAGE_PIN R22 IOSTANDARD LVCMOS33 } [get_ports flash_miso]
set_property -dict { PACKAGE_PIN P21 IOSTANDARD LVCMOS33 } [get_ports flash_wp_n]
set_property -dict { PACKAGE_PIN R21 IOSTANDARD LVCMOS33 } [get_ports flash_hold_n]
