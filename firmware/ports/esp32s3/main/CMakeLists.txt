idf_component_register(SRCS "main.c" "cmd_profile.c"
                       REQUIRES fpga_link profile_mgr console esp_timer esp_driver_gpio)
