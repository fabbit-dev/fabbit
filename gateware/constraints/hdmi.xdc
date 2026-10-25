# HDMI1 девборды i5/i9 (через 0,1 мкФ C6..C13), банк 34, 3,3 В. Линии: [0] D0, [1] D1, [2] D2, [3] CLK.
# Пары не IO_L P/N: каждая ножка одиночный LVCMOS33 (tmds_phy_se). DRIVE 4: с DRIVE 8 монитор
# показывал чёрный экран без «нет сигнала», с DRIVE 4 картинка есть (стенд, 2026-10-20).
set_property -dict { PACKAGE_PIN AB6 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 4 } [get_ports {hdmi_p[0]}]
set_property -dict { PACKAGE_PIN AA5 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 4 } [get_ports {hdmi_n[0]}]
set_property -dict { PACKAGE_PIN AB7 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 4 } [get_ports {hdmi_p[1]}]
set_property -dict { PACKAGE_PIN Y7  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 4 } [get_ports {hdmi_n[1]}]
set_property -dict { PACKAGE_PIN W7  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 4 } [get_ports {hdmi_p[2]}]
set_property -dict { PACKAGE_PIN Y8  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 4 } [get_ports {hdmi_n[2]}]
set_property -dict { PACKAGE_PIN AB5 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 4 } [get_ports {hdmi_p[3]}]
set_property -dict { PACKAGE_PIN AA4 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 4 } [get_ports {hdmi_n[3]}]
