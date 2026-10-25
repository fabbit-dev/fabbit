# Профиль из слота флеша (Vivado): CCLK 33 МГц и сжатие, как у golden. Без них поток читается
# на ~3 МГц, а править COR0 в готовом битстриме нельзя: у Vivado в потоке есть CRC.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
