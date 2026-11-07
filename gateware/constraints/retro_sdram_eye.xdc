# diag/retro_sdram_eye: как в образе ретро-профиля, регистры команд НЕ в IOB (в образе за ними
# стоит владелец шины SDRAM). Шина ESP ↔ память: только sync_bit и регистры, которые читают,
# когда тестер стоит.
set_property IOB FALSE [get_ports {sdram_a[*] sdram_ba[*] sdram_ras_n sdram_cas_n sdram_we_n}]
set retro_eye_bus [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *u_bus/u_pll/CLKOUT0}]]
set retro_eye_mem [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *u_mem/CLKOUT*}]]
set_clock_groups -asynchronous -group $retro_eye_bus -group $retro_eye_mem
