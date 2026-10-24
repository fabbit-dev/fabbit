# Такты nes_clocks: clk = fclk / 3 с одного MMCM, фронты совпадают. Путь clk → fclk: 3 такта fclk,
# fclk → clk: 2 (как nano20k.sdc ядра NESTang: запросы в окне clkref, данные через слот).
set nes_clk  [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *u_nesclk/u_mmcm/CLKOUT0}]]
set nes_fclk [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *u_nesclk/u_mmcm/CLKOUT1}]]
set_multicycle_path 3 -setup -end   -from $nes_clk  -to $nes_fclk
set_multicycle_path 2 -hold  -end   -from $nes_clk  -to $nes_fclk
set_multicycle_path 2 -setup -start -from $nes_fclk -to $nes_clk
set_multicycle_path 1 -hold  -start -from $nes_fclk -to $nes_clk
# шина ESP (PLL 100 МГц) ↔ ядро: через границу только sync_bit и регистры, которые читают, когда
# они стоят (sdram_eye: бит «тестер стоит»)
set bus_clk [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *u_bus/u_pll/CLKOUT0}]]
set_clock_groups -asynchronous -group $bus_clk -group [list $nes_clk $nes_fclk]
