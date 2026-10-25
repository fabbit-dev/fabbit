file(GLOB ASSETS "assets/*.c")
idf_component_register(SRCS "ui.c" ${ASSETS}
                       INCLUDE_DIRS "include")
