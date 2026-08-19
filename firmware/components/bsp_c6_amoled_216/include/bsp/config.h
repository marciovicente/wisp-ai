/* Tipos compartilhados entre display.h e touch.h.
 *
 * Existe para quebrar o ciclo: bsp_touch_new() recebe bsp_display_cfg_t, que
 * no BSP oficial mora no header agregador — e o agregador inclui touch.h. */
#pragma once

#include "esp_lv_adapter.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Mesmos campos e mesma ordem do BSP da placa S3
 * (waveshare/esp32_s3_touch_amoled_2_16 v2.0.1). O firmware preenche esta
 * struct por designated initializers, então acrescentar campo no fim é seguro;
 * reordenar não. */
typedef struct {
    esp_lv_adapter_config_t          lv_adapter_cfg;
    esp_lv_adapter_rotation_t        rotation;
    esp_lv_adapter_tear_avoid_mode_t tear_avoid_mode;
    struct {
        unsigned int swap_xy;
        unsigned int mirror_x;
        unsigned int mirror_y;
    } touch_flags;
} bsp_display_cfg_t;

#ifdef __cplusplus
}
#endif
