idf_component_register(SRCS "main.c" "cmd_profile.c" "cmd_pad.c"
                       REQUIRES fpga_link profile_mgr input pad console esp_timer esp_driver_gpio)
