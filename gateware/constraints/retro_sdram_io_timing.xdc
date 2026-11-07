# Внешний тайминг SDRAM M12L64322A (ESMT 2S, rev 1.0, с. 6–7), класс −7: маркировка чипа
# на модуле (M12L64322A-ASS2POARW01) класса скорости не подтверждает.
# sdram_clk — копия такта контроллера через ODDR: описан как сгенерированный такт на выводе.
# Длины дорожек модуля i9+ неизвестны. Консервативная оценка пролёта, одна для такта и
# линий данных/команд: 0,2–0,8 нс. Это условная подпись, не измерение платы.
# Переменные: retro_sdram_fwd — ячейка ODDR такта SDRAM, retro_sdram_cas — CAS latency.
#   tSS (setup на входе SDRAM)       2,0 нс   tSH (hold)            1,5 нс
#   tSAC CL2 / CL3 (такт→данные max) 8,0 / 6,0 нс   tOH (удержание min)   2,0 нс
if {![info exists retro_sdram_fwd]} {error "retro SDRAM I/O: set retro_sdram_fwd to the ODDR cell"}
if {![info exists retro_sdram_cas]} {error "retro SDRAM I/O: set retro_sdram_cas (2 or 3)"}
set retro_io_board_min 0.2
set retro_io_board_max 0.8
set retro_io_fwd [get_cells $retro_sdram_fwd]
if {[llength $retro_io_fwd] != 1} {error "retro SDRAM I/O: ODDR $retro_sdram_fwd not found"}
set retro_io_src [get_clocks -of_objects [get_pins $retro_sdram_fwd/C]]
if {[llength $retro_io_src] != 1} {error "retro SDRAM I/O: ODDR clock not unique"}
create_generated_clock -name sdram_pin_clk -source [get_pins $retro_sdram_fwd/C] \
    -multiply_by 1 [get_ports sdram_clk]
# Команды/адрес и данные записи: выходы, захват SDRAM по переднему фронту sdram_pin_clk.
# Пролёт данных и такта считается независимым: худший случай max данных + min такта.
set retro_io_out [get_ports {sdram_a[*] sdram_ba[*] sdram_ras_n sdram_cas_n sdram_we_n sdram_dq[*]}]
set_output_delay -clock sdram_pin_clk -max [expr {2.0 + $retro_io_board_max - $retro_io_board_min}] $retro_io_out
set_output_delay -clock sdram_pin_clk -min [expr {-1.5 + $retro_io_board_min - $retro_io_board_max}] $retro_io_out
# Чтение: данные меняются после фронта sdram_pin_clk через tOH..tSAC плюс пролёт туда-обратно.
if {$retro_sdram_cas == 2} {set retro_io_tac 8.0} else {set retro_io_tac 6.0}
set retro_io_in [get_ports {sdram_dq[*]}]
set_input_delay -clock sdram_pin_clk -max [expr {$retro_io_tac + 2*$retro_io_board_max}] $retro_io_in
set_input_delay -clock sdram_pin_clk -min [expr {2.0 + 2*$retro_io_board_min}] $retro_io_in
# Связи фронтов по умолчанию и есть расписание контроллера: команда с фронта c ловится
# ближайшим фронтом sdram_pin_clk (c+фаза), данные чтения, выданные фронтом k+CL−1 вывода,
# захватываются ближайшим следующим фронтом контроллера (c+CL). Многотактных исключений нет.
puts "retro SDRAM I/O: CL$retro_sdram_cas, board $retro_io_board_min..$retro_io_board_max ns, [llength $retro_io_out] out, [llength $retro_io_in] in"
