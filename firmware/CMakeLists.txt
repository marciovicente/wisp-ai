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
spiffs_create_partition_assets(
    storage
    "${CMAKE_CURRENT_SOURCE_DIR}/assets"
    FLASH_IN_PROJECT
    MMAP_FILE_SUPPORT_FORMAT ".png"
    MMAP_SUPPORT_RAW 1
    MMAP_RAW_FILE_FORMAT "true_color_alpha"
    MMAP_RAW_COLOR_FORMAT "RGB565A8"
)
