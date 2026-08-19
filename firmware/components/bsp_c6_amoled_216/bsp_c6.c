/* Implementação do BSP mínimo da ESP32-C6-Touch-AMOLED-2.16".
 * Ver include/bsp/esp-bsp.h para o porquê deste componente existir. */

#include "bsp/esp-bsp.h"

#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_lcd_co5300.h"
#include "esp_lcd_touch_cst9217.h"
#include "esp_check.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "bsp_c6";

/* ————————————————————————————————————————————————
 *  Mapa de pinos
 *
 *  Conferido no esquemático da placa e no exemplo oficial
 *  (waveshareteam/ESP32-C6-Touch-AMOLED-2.16, 09_LVGL_V9_Test).
 *
 *  ARMADILHA: o user_config.h do exemplo oficial lista LCD_CS=5 e
 *  TOUCH_INT=15, mas o main.cpp dele nunca passa esses valores — usa os
 *  defaults do construtor de DisplayPort, que são CS=15 e INT=5. Os defaults
 *  é que batem com o esquemático; o user_config.h tem os dois trocados.
 * ———————————————————————————————————————————————— */
#define BSP_I2C_SCL     GPIO_NUM_7
#define BSP_I2C_SDA     GPIO_NUM_8

#define BSP_LCD_PCLK    GPIO_NUM_0
#define BSP_LCD_DATA0   GPIO_NUM_1
#define BSP_LCD_DATA1   GPIO_NUM_2
#define BSP_LCD_DATA2   GPIO_NUM_3
#define BSP_LCD_DATA3   GPIO_NUM_4
#define BSP_LCD_CS      GPIO_NUM_15

#define BSP_TOUCH_INT   GPIO_NUM_5
#define BSP_TOUCH_RST   GPIO_NUM_11

/* ————————————————————————————————————————————————
 *  PMIC — só o suficiente para o painel ter energia
 *
 *  Esta placa não tem pino de reset nem de backlight no display: o rail do
 *  AMOLED é o ALDO3 do AXP2101, e "resetar o painel" significa desligar e
 *  ligar esse rail. Sem isso a tela fica preta com o firmware rodando — o
 *  sintoma mais comum de porte mal feito nesta placa.
 *
 *  Falo I2C por registrador em vez de trazer a XPowersLib (C++, ~250KB de
 *  headers) porque são três escritas. Os endereços vêm dos constants oficiais:
 *    0x90 bit2 = liga/desliga ALDO3
 *    0x94 5 bits = tensão do ALDO3, (mV-500)/100
 *  A leitura de bateria continua em pmic.c, no firmware — este arquivo não
 *  compete com ele: são dispositivos I2C separados no mesmo barramento.
 * ———————————————————————————————————————————————— */
#define AXP_ADDR            0x34
#define AXP_LDO_ONOFF_CTRL0 0x90
#define AXP_ALDO3_VOL_CTRL  0x94
#define AXP_ALDO3_BIT       2
#define AXP_ALDO3_3V3       0x1C   /* (3300 - 500) / 100 */

static i2c_master_bus_handle_t s_i2c;
static i2c_master_dev_handle_t s_axp;
static esp_lcd_panel_handle_t s_panel;
static esp_lcd_panel_io_handle_t s_io;
static int s_brightness = 100;

esp_err_t bsp_i2c_init(void)
{
    if (s_i2c) return ESP_OK;

    const i2c_master_bus_config_t cfg = {
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .i2c_port = BSP_I2C_NUM,
        .scl_io_num = BSP_I2C_SCL,
        .sda_io_num = BSP_I2C_SDA,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    esp_err_t err = i2c_new_master_bus(&cfg, &s_i2c);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "I2C não subiu: %s", esp_err_to_name(err));
        s_i2c = NULL;
    }
    return err;
}

i2c_master_bus_handle_t bsp_i2c_get_handle(void)
{
    return s_i2c;
}

static esp_err_t axp_open(void)
{
    if (s_axp) return ESP_OK;
    const i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = AXP_ADDR,
        .scl_speed_hz = 100000,
    };
    return i2c_master_bus_add_device(s_i2c, &cfg, &s_axp);
}

static esp_err_t axp_write(uint8_t reg, uint8_t val)
{
    const uint8_t buf[2] = {reg, val};
    return i2c_master_transmit(s_axp, buf, sizeof(buf), 200);
}

static esp_err_t axp_bit(uint8_t reg, uint8_t bit, bool on)
{
    uint8_t v = 0;
    esp_err_t err = i2c_master_transmit_receive(s_axp, &reg, 1, &v, 1, 200);
    if (err != ESP_OK) return err;
    v = on ? (v | (1u << bit)) : (v & ~(1u << bit));
    return axp_write(reg, v);
}

/* off -> on com pausas, que é o que os exemplos oficiais fazem antes do
 * esp_lcd_panel_init(). A primeira ativação existe para o caso de a tela já
 * estar ligada (reboot por software): sem desligar antes, o painel não recebe
 * o power-on reset e a tabela de init pode ser aplicada em cima de um estado
 * sujo. */
static esp_err_t painel_energizar(void)
{
    ESP_RETURN_ON_ERROR(axp_open(), TAG, "AXP2101 não abriu");
    ESP_RETURN_ON_ERROR(axp_write(AXP_ALDO3_VOL_CTRL, AXP_ALDO3_3V3), TAG, "ALDO3 3V3");

    ESP_RETURN_ON_ERROR(axp_bit(AXP_LDO_ONOFF_CTRL0, AXP_ALDO3_BIT, true), TAG, "ALDO3 on");
    vTaskDelay(pdMS_TO_TICKS(100));
    ESP_RETURN_ON_ERROR(axp_bit(AXP_LDO_ONOFF_CTRL0, AXP_ALDO3_BIT, false), TAG, "ALDO3 off");
    vTaskDelay(pdMS_TO_TICKS(100));
    ESP_RETURN_ON_ERROR(axp_bit(AXP_LDO_ONOFF_CTRL0, AXP_ALDO3_BIT, true), TAG, "ALDO3 on");
    vTaskDelay(pdMS_TO_TICKS(100));

    ESP_LOGI(TAG, "ALDO3 (rail do AMOLED) ligado");
    return ESP_OK;
}

/* ————————————————————————————————————————————————
 *  Display
 *
 *  Tabela copiada byte a byte do BSP da placa S3, incluindo o MADCTL 0xA0 —
 *  ver a explicação em include/bsp/esp-bsp.h. É a mesma sequência do exemplo
 *  oficial do C6, que só difere na ordem do 0x36 e no delay do 0x29.
 * ———————————————————————————————————————————————— */
static const co5300_lcd_init_cmd_t lcd_init_cmds[] = {
    {0x11, (uint8_t[]){0x00}, 0, 600},                    /* sleep out */

    {0xFE, (uint8_t[]){0x20}, 1, 0},                      /* página de registro 0x20 */
    {0x19, (uint8_t[]){0x10}, 1, 0},
    {0x1C, (uint8_t[]){0xA0}, 1, 0},

    {0xFE, (uint8_t[]){0x00}, 1, 0},                      /* volta para a página do usuário */
    {0xC4, (uint8_t[]){0x80}, 1, 0},
    {0x3A, (uint8_t[]){0x55}, 1, 0},                      /* RGB565 */
    {0x35, (uint8_t[]){0x00}, 1, 0},                      /* tearing effect */
    {0x53, (uint8_t[]){0x20}, 1, 0},
    {0x51, (uint8_t[]){0xFF}, 1, 0},                      /* brilho máximo */
    {0x63, (uint8_t[]){0xFF}, 1, 0},
    {0x2A, (uint8_t[]){0x00, 0x00, 0x01, 0xDF}, 4, 0},    /* colunas 0..479 */
    {0x2B, (uint8_t[]){0x00, 0x00, 0x01, 0xDF}, 4, 0},    /* linhas 0..479 */
    {0x36, (uint8_t[]){0xA0}, 1, 0},                      /* MADCTL base */
    {0x29, (uint8_t[]){0x00}, 0, 600},                    /* display on */
};

esp_err_t bsp_display_new(const bsp_display_config_t *config,
                          esp_lcd_panel_handle_t *ret_panel,
                          esp_lcd_panel_io_handle_t *ret_io)
{
    ESP_RETURN_ON_FALSE(config && config->max_transfer_sz > 0, ESP_ERR_INVALID_ARG,
                        TAG, "max_transfer_sz é obrigatório");

    ESP_RETURN_ON_ERROR(bsp_i2c_init(), TAG, "I2C");
    ESP_RETURN_ON_ERROR(painel_energizar(), TAG, "energia do painel");

    ESP_LOGI(TAG, "subindo o barramento QSPI");
    const spi_bus_config_t buscfg = CO5300_PANEL_BUS_QSPI_CONFIG(BSP_LCD_PCLK,
                                                                 BSP_LCD_DATA0,
                                                                 BSP_LCD_DATA1,
                                                                 BSP_LCD_DATA2,
                                                                 BSP_LCD_DATA3,
                                                                 config->max_transfer_sz);
    ESP_RETURN_ON_ERROR(spi_bus_initialize(BSP_LCD_SPI_NUM, &buscfg, SPI_DMA_CH_AUTO),
                        TAG, "spi_bus_initialize");

    esp_lcd_panel_io_spi_config_t io_config = CO5300_PANEL_IO_QSPI_CONFIG(BSP_LCD_CS, NULL, NULL);
    /* 3, como no BSP do S3. O default do macro é 10, e cada slot da fila custa
     * RAM interna — o recurso escasso desta placa. */
    io_config.trans_queue_depth = 3;

    co5300_vendor_config_t vendor_config = {
        .init_cmds = lcd_init_cmds,
        .init_cmds_size = sizeof(lcd_init_cmds) / sizeof(lcd_init_cmds[0]),
        .flags = {.use_qspi_interface = 1},
    };
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t) BSP_LCD_SPI_NUM,
                                                 &io_config, &s_io),
                        TAG, "panel_io");

    const esp_lcd_panel_dev_config_t panel_config = {
        .reset_gpio_num = GPIO_NUM_NC,   /* não existe: o reset é o ALDO3 */
        .rgb_ele_order = BSP_LCD_COLOR_SPACE,
        .bits_per_pixel = BSP_LCD_BITS_PER_PIXEL,
        .vendor_config = &vendor_config,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_co5300(s_io, &panel_config, &s_panel), TAG, "co5300");

    ESP_RETURN_ON_ERROR(esp_lcd_panel_reset(s_panel), TAG, "reset");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_init(s_panel), TAG, "init");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_disp_on_off(s_panel, true), TAG, "disp_on");

    if (ret_panel) *ret_panel = s_panel;
    if (ret_io) *ret_io = s_io;
    ESP_LOGI(TAG, "painel CO5300 %dx%d pronto", BSP_LCD_H_RES, BSP_LCD_V_RES);
    return ESP_OK;
}

esp_err_t bsp_display_brightness_set(int brightness_percent)
{
    if (!s_panel) return ESP_ERR_INVALID_STATE;
    if (brightness_percent > 100) brightness_percent = 100;
    if (brightness_percent < 0) brightness_percent = 0;
    esp_err_t err = esp_lcd_panel_co5300_set_brightness(s_panel, (uint8_t) brightness_percent);
    if (err == ESP_OK) s_brightness = brightness_percent;
    return err;
}

int bsp_display_brightness_get(void)
{
    return s_brightness;
}

esp_err_t bsp_display_brightness_init(void)
{
    return bsp_display_brightness_set(100);
}

esp_err_t bsp_display_backlight_on(void)
{
    return bsp_display_brightness_set(100);
}

esp_err_t bsp_display_backlight_off(void)
{
    return bsp_display_brightness_set(0);
}

/* ————————————————————————————————————————————————
 *  Touch
 * ———————————————————————————————————————————————— */
esp_err_t bsp_touch_new(const bsp_display_cfg_t *cfg, esp_lcd_touch_handle_t *ret_touch)
{
    ESP_RETURN_ON_FALSE(ret_touch, ESP_ERR_INVALID_ARG, TAG, "ret_touch nulo");
    ESP_RETURN_ON_ERROR(bsp_i2c_init(), TAG, "I2C");

    const esp_lcd_touch_config_t tp_cfg = {
        .x_max = BSP_LCD_H_RES,
        .y_max = BSP_LCD_V_RES,
        .rst_gpio_num = BSP_TOUCH_RST,
        .int_gpio_num = BSP_TOUCH_INT,
        .levels = {
            .reset = 0,
            .interrupt = 0,
        },
        .flags = {
            .swap_xy  = cfg ? cfg->touch_flags.swap_xy  : 1,
            .mirror_x = cfg ? cfg->touch_flags.mirror_x : 0,
            .mirror_y = cfg ? cfg->touch_flags.mirror_y : 1,
        },
    };

    esp_lcd_panel_io_handle_t tp_io = NULL;
    esp_lcd_panel_io_i2c_config_t tp_io_config = ESP_LCD_TOUCH_IO_I2C_CST9217_CONFIG();
    tp_io_config.scl_speed_hz = 400000;
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_io_i2c(s_i2c, &tp_io_config, &tp_io), TAG, "touch io");
    return esp_lcd_touch_new_i2c_cst9217(tp_io, &tp_cfg, ret_touch);
}

/* ————————————————————————————————————————————————
 *  Mutex do LVGL
 * ———————————————————————————————————————————————— */
bool bsp_display_lock(uint32_t timeout_ms)
{
    /* O firmware chama bsp_display_lock(-1) querendo espera infinita. Como o
     * parâmetro é uint32_t (assinatura do BSP original), -1 chega aqui como
     * UINT32_MAX; o adapter espera -1 num int. Traduzir aqui é o que faz o
     * "-1" do chamador significar de fato "espere para sempre". */
    int t = (timeout_ms == UINT32_MAX) ? -1 : (int) timeout_ms;
    return esp_lv_adapter_lock(t) == ESP_OK;
}

void bsp_display_unlock(void)
{
    esp_lv_adapter_unlock();
}
