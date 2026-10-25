# Colorlight i9+ 6.0: такт, LED D2, UART TX -> DAPLink (SODIMM 84)
set_property -dict { PACKAGE_PIN K4  IOSTANDARD LVCMOS33 } [get_ports clk]
set_property -dict { PACKAGE_PIN A18 IOSTANDARD LVCMOS33 } [get_ports led]
set_property -dict { PACKAGE_PIN R3  IOSTANDARD LVCMOS33 } [get_ports uart_tx]
