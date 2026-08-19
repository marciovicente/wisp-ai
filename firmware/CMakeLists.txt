cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(wisp)

# Packs the mascots into the `storage` partition (7MB, empty until now).
#
# MMAP_SUPPORT_RAW converts the PNGs into RAW bitmaps at build time. That is
# the difference between decoding PNG at boot — which would need a temporary
# buffer in internal RAM, the scarcest resource on this board — and simply
# pointing at bytes already sitting in flash, mapped with no copy at all.
#
# RGB565A8: 565 colour with a separate alpha channel — the name LVGL 9 uses,
# and the only alpha format that works here, because the characters have their
# background cut out.
# Arte 30% maior no C6 (306x306 contra 236x236).
#
# Escalar em tempo de execucao com lv_image_set_scale() seria uma linha, e sai
# caro no lugar errado: o C6 e single-core e a animacao ja e o gargalo desta
# placa. Reamostrar no build custa flash — 2,1MB de RAW contra 1,3MB, e por
# isso a particao de assets do C6 tem 3MB — e nao custa nada por quadro.
#
# A pasta original fica intacta para a placa S3.
set(WISP_ASSETS "${CMAKE_CURRENT_SOURCE_DIR}/assets")
if("${IDF_TARGET}" STREQUAL "esp32c6")
    set(WISP_ASSETS "${CMAKE_CURRENT_SOURCE_DIR}/assets_c6")
endif()

spiffs_create_partition_assets(
    storage
    "${WISP_ASSETS}"
    FLASH_IN_PROJECT
    MMAP_FILE_SUPPORT_FORMAT ".png"
    MMAP_SUPPORT_RAW 1
    MMAP_RAW_FILE_FORMAT "true_color_alpha"
    MMAP_RAW_COLOR_FORMAT "RGB565A8"
)
