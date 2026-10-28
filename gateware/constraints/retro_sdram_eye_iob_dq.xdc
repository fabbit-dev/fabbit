# diag/retro_sdram_eye A/B, вариант 3: ещё и DQ (данные записи, захват чтения) в IOB.
set_property IOB TRUE [get_ports {sdram_dq[*]}]
