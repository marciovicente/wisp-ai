# Este componente só existe para o ESP32-C6. Em esp32s3 quem fornece os headers
# bsp/* é o BSP oficial da Waveshare, e ter os dois no build seria conflito de
# include — então aqui ele se registra vazio e sai de cena.
if(NOT "${IDF_TARGET}" STREQUAL "esp32c6")
    idf_component_register()
    return()
endif()

idf_component_register(
    SRCS "bsp_c6.c"
    INCLUDE_DIRS "include"
    REQUIRES esp_driver_i2c esp_driver_spi esp_driver_gpio esp_lcd
)
