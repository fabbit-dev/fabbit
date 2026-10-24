cmake_minimum_required(VERSION 3.22)
# переносимые компоненты (ui, launcher): общие для портов esp32s3, ch32h417, pcsim
set(EXTRA_COMPONENT_DIRS ../../components)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(fabbit_loader)

# образ FAT с профилями из profiles/ корня репозитория (*.fbp): build/storage.bin, пишется в раздел storage
fatfs_create_rawflash_image(storage ../../../profiles)
