# Такт модуля 25 МГц (K4): от него Vivado и nextpnr выводят такты MMCM
create_clock -period 40.000 -name clk25 [get_ports clk]
