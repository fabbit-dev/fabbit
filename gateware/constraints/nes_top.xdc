# Профиль NES: видео (video_clocks) не связано с тактами ядра и шины. Через границу идёт только
# буфер кадра ram_sdp (два порта, каждый в своём такте), управление видео — своё.
set vid_clks [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *u_vclk/u_mmcm/CLKOUT*}]]
set_clock_groups -asynchronous -group $vid_clks -group [list $nes_clk $nes_fclk $bus_clk]
# FIFO потока ROM (шина → ядро): указатели Грея, задержка не больше периода быстрого такта
set_max_delay -datapath_only 10.0 -from [get_cells -hier -filter {NAME =~ *u_fifo/wgray_q_reg*}] -to [get_cells -hier -filter {NAME =~ *u_fifo/wgray_s1_reg*}]
set_max_delay -datapath_only 10.0 -from [get_cells -hier -filter {NAME =~ *u_fifo/rgray_q_reg*}] -to [get_cells -hier -filter {NAME =~ *u_fifo/rgray_s1_reg*}]
# слово пада (cdc_word): шина → ядро, переключатель через sync_bit, слово стоит ≥ 2 тактов ядра
set_max_delay -datapath_only 10.0 -from [get_cells -hier -filter {NAME =~ *u_padx/word_q_reg*}] -to [get_cells -hier -filter {NAME =~ *u_padx/q_reg*}]
