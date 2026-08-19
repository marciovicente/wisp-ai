# Na placa S3 quem fornece os headers bsp/* — e, de carona, o driver de GPIO —
# é o BSP oficial da Waveshare, que entra por dependência do idf_component.yml.
# No C6 o substituto é um componente local (components/bsp_c6_amoled_216), e
# componente local não vira dependência sozinho quando REQUIRES é explícito.
set(reqs nvs_flash esp_wifi esp_netif esp_http_client json)
if("${IDF_TARGET}" STREQUAL "esp32c6")
    list(APPEND reqs bsp_c6_amoled_216 esp_driver_gpio)
endif()

idf_component_register(
    SRCS "main.c" "ui.c" "pmic.c"
    INCLUDE_DIRS "."
    REQUIRES ${reqs}
)
