# Golden: шина ESP (PLL 100 МГц) и видео (video_clocks) не связаны. Через границу идут память
# плоскости (ram_sdp, каждый порт в своём такте), счётчик кадров через sync_bit, палитра и
# CTRL osd_plane: меняются редко, смена портит не больше одного кадра.
set bus_clk [get_clocks -of_objects [get_pins u_pll/CLKOUT0]]
set vid_clks [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *u_vclk/u_mmcm/CLKOUT*}]]
set_clock_groups -asynchronous -group $bus_clk -group $vid_clks
