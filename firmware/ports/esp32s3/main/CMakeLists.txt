idf_component_register(SRCS "main.c" "cmd_profile.c" "cmd_pad.c" "cmd_capture.c" "launcher_port.c"
                       REQUIRES fpga_link profile_mgr input pad nes_rom la_capture ui launcher nvs_flash console esp_timer esp_driver_gpio)
