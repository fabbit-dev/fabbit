# diag/retro_sdram_eye A/B: команды и адрес в IOB, как задаёт sdram.xdc для одного контроллера.
# Шина ESP ↔ память: только sync_bit и регистры, которые читают, когда тестер стоит.
set retro_eye_bus [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *u_bus/u_pll/CLKOUT0}]]
set retro_eye_mem [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *u_mem/CLKOUT*}]]
set_clock_groups -asynchronous -group $retro_eye_bus -group $retro_eye_mem
