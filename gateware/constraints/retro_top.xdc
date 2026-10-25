# Reuse existing verified board pin XDCs; this file adds only timing relationships.
# Legacy sdram.xdc assumes ONE controller's output flop directly at the pin.
# The shared owner mux invalidates that IOB packing request; not an I/O waiver.
# Timing remains reported/unconstrained until shared physical path signoff.
set_property IOB FALSE [get_ports {sdram_a[*] sdram_ba[*] sdram_ras_n sdram_cas_n sdram_we_n}]
# All data crossings use declared synchronizers, bundled mailbox or asynchronous FIFOs.
set all_async [get_cells -hier -filter {ASYNC_REG == TRUE}]
set_false_path -to [get_pins -of_objects $all_async -filter {REF_PIN_NAME == D}]
# Bundled data remains fixed through toggle round trip. Bound physical skew, not
# a blanket false path on unrelated logic.
# Mailbox capture endpoints and Gray FIFO paths are reviewed after synthesis;
# no blanket port/clock exceptions are applied to conceal a failing crossing.
# Native SDRAM clock changes only with controllers reset, NOP and DQ tri-stated.
# Physically exclusive alternatives on the two dedicated glitch-free BUFGCTRLs.
set_clock_groups -physically_exclusive \
    -group [get_clocks -of_objects [get_pins u_nesclk/u_mmcm/CLKOUT2]] \
    -group [get_clocks -of_objects [get_pins u_retroclk/u_mmcm/CLKOUT3]] \
    -group [get_clocks -of_objects [get_pins u_snesclk/mmcm/CLKOUT2]]
# Existing NES controller 1:3 schedule, preserved from nes_clocks.xdc.
set nes_clk [get_clocks -of_objects [get_pins u_nesclk/u_mmcm/CLKOUT0]]
set nes_fclk [get_clocks -of_objects [get_pins u_nesclk/u_mmcm/CLKOUT1]]
set_multicycle_path 3 -setup -end -from $nes_clk -to $nes_fclk
set_multicycle_path 2 -hold -end -from $nes_clk -to $nes_fclk
set_multicycle_path 2 -setup -start -from $nes_fclk -to $nes_clk
set_multicycle_path 1 -hold -start -from $nes_fclk -to $nes_clk
