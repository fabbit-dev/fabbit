idf_component_register(SRCS "main.c" "cmd_profile.c" "cmd_pad.c" "launcher_port.c" "rom_port.c"
                       REQUIRES fpga_link profile_mgr input pad nes_rom retro_rom rom ui launcher nvs_flash console esp_timer esp_driver_gpio)
