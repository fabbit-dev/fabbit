cmake_minimum_required(VERSION 3.22)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(fabbit_loader)

# образ FAT с профилями из profiles/ корня репозитория (*.fbp): build/storage.bin, пишется в раздел storage
fatfs_create_rawflash_image(storage ../../../profiles)
