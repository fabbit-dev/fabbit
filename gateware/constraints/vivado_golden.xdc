# Только для Vivado: такт, конфигурация, мультизагрузка
create_clock -period 40.000 -name clk25 [get_ports clk]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property BITSTREAM.CONFIG.CONFIGFALLBACK ENABLE [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
# шина ESP асинхронна, синхронизаторы в qspi_slave
set_false_path -from [get_ports {esp_sck esp_cs_n esp_d[*]}]
set_false_path -to [get_ports {esp_d[*] esp_irq led uart_tx}]
