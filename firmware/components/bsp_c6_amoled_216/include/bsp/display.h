#pragma once

#include "esp_lcd_types.h"
#include "bsp/config.h"

/* O painel é o mesmo módulo CO5300 da placa S3: 480x480, RGB565, QSPI. */
#define BSP_LCD_COLOR_FORMAT_RGB565 (1)
#define BSP_LCD_COLOR_FORMAT        (BSP_LCD_COLOR_FORMAT_RGB565)
#define BSP_LCD_BITS_PER_PIXEL      (16)
#define BSP_LCD_COLOR_SPACE         (LCD_RGB_ELEMENT_ORDER_RGB)
#define BSP_LCD_H_RES               (480)
#define BSP_LCD_V_RES               (480)
#define BSP_LCD_SPI_NUM             (SPI2_HOST)

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int max_transfer_sz;    /*!< Tamanho máximo de transferência, em bytes. */
} bsp_display_config_t;

/* Liga o rail do AMOLED no PMIC, sobe o barramento QSPI e inicializa o painel.
 *
 * Diferença que importa em relação ao BSP do S3: aqui esta função também
 * inicializa o I2C, porque sem o AXP2101 o painel não tem energia (não existe
 * pino de reset nem de backlight nesta placa). Como efeito colateral,
 * bsp_i2c_get_handle() passa a ser válido a partir daqui, e não só depois do
 * bsp_touch_new(). */
esp_err_t bsp_display_new(const bsp_display_config_t *config,
                          esp_lcd_panel_handle_t *ret_panel,
                          esp_lcd_panel_io_handle_t *ret_io);

/* Brilho não é PWM: é o registrador 0x51 do painel. "init" aqui só significa
 * acender em 100%, para casar com a semântica do BSP oficial. */
esp_err_t bsp_display_brightness_init(void);
esp_err_t bsp_display_brightness_set(int brightness_percent);
int       bsp_display_brightness_get(void);
esp_err_t bsp_display_backlight_on(void);
esp_err_t bsp_display_backlight_off(void);

#ifdef __cplusplus
}
#endif
