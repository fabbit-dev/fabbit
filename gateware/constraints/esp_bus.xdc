# Шина ESP32-S3 (макет): гребёнка P3 девборды i5/i9, банк 14 (3,3 В, там же флеш конфигурации)
# P3-7  (i5 C4) -> Y18 MRCC: SCK   | P3-9  (C3) -> W19: CS#
# P3-12 (A3) -> Y19: D0 (ESP GPIO11) | P3-13 (B1) -> V18: D1 (GPIO13)
# P3-17 (C1) -> V19: D2 (GPIO14)     | P3-16 (D1) -> AA20: D3 (GPIO9)
# P3-15 (E2) -> AA21: IRQ (GPIO46)
set_property -dict { PACKAGE_PIN Y18  IOSTANDARD LVCMOS33 } [get_ports esp_sck]
set_property -dict { PACKAGE_PIN W19  IOSTANDARD LVCMOS33 PULLUP TRUE } [get_ports esp_cs_n]
set_property -dict { PACKAGE_PIN Y19  IOSTANDARD LVCMOS33 } [get_ports {esp_d[0]}]
set_property -dict { PACKAGE_PIN V18  IOSTANDARD LVCMOS33 } [get_ports {esp_d[1]}]
set_property -dict { PACKAGE_PIN V19  IOSTANDARD LVCMOS33 } [get_ports {esp_d[2]}]
set_property -dict { PACKAGE_PIN AA20 IOSTANDARD LVCMOS33 } [get_ports {esp_d[3]}]
set_property -dict { PACKAGE_PIN AA21 IOSTANDARD LVCMOS33 } [get_ports esp_irq]
