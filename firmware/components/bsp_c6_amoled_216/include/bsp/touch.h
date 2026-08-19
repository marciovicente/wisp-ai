#pragma once

#include "esp_lcd_touch.h"
#include "bsp/config.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Touch CST9220 no I2C 0x5A (o componente do CST9217 cobre a mesma família).
 * Usa cfg->touch_flags para o espelhamento, igual ao BSP do S3. */
esp_err_t bsp_touch_new(const bsp_display_cfg_t *cfg, esp_lcd_touch_handle_t *ret_touch);

#ifdef __cplusplus
}
#endif
