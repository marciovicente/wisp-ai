cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(fagulha)

# Empacota os mascotes na particao `storage` (7MB, ate agora vazia).
#
# MMAP_SUPPORT_RAW converte os PNG para bitmap CRU em tempo de compilacao. E
# a diferenca entre decodificar PNG no boot — que pediria buffer temporario da
# RAM interna, o recurso mais escasso desta placa — e simplesmente apontar
# para os bytes ja prontos na flash, mapeados sem copia nenhuma.
#
# RGB565A8: cor em 565 com canal alfa separado — o nome que o LVGL 9 usa, e
# o unico formato com alfa que serve, porque os bonecos tem fundo recortado.
spiffs_create_partition_assets(
    storage
    "${CMAKE_CURRENT_SOURCE_DIR}/assets"
    FLASH_IN_PROJECT
    MMAP_FILE_SUPPORT_FORMAT ".png"
    MMAP_SUPPORT_RAW 1
    MMAP_RAW_FILE_FORMAT "true_color_alpha"
    MMAP_RAW_COLOR_FORMAT "RGB565A8"
)
