/* BSP mínimo da Waveshare ESP32-C6-Touch-AMOLED-2.16".
 *
 * POR QUE ESTE ARQUIVO EXISTE
 * ---------------------------
 * O firmware do Wisp foi escrito para a placa S3 e usa o BSP oficial dela,
 * `waveshare/esp32_s3_touch_amoled_2_16`. Esse componente declara
 * `targets: [esp32s3]` e não existe versão para o C6 no registro da Espressif
 * (verificado: 404).
 *
 * A boa notícia é que a superfície de contato é pequena — o firmware usa nove
 * símbolos do BSP e fala com o LVGL direto pelo esp_lvgl_adapter. Este
 * componente reimplementa exatamente esses nove para o C6, com os mesmos
 * nomes e assinaturas, e por isso main.c e ui.c compilam sem alteração nos
 * includes.
 *
 * O QUE MUDA NO HARDWARE (e por isso não é só recompilar)
 * ------------------------------------------------------
 *   - RISC-V single-core, 512KB de SRAM, SEM PSRAM (o C6 não tem interface).
 *   - Pinos diferentes: QSPI em 0/1/2/3/4 com CS em 15; I2C em 7/8.
 *   - Touch CST9220 (família CST9217), não o CST9217 puro do S3 — mesmo
 *     componente de driver serve.
 *
 * O QUE NÃO MUDA
 * --------------
 * O painel é o mesmo CO5300 480x480 e a tabela de init é a mesma, byte a byte,
 * do BSP do S3 — inclusive o MADCTL base 0xA0. Isso é deliberado: a rotação do
 * firmware está calibrada em cima desse valor (ver aplicar_rotacao() em
 * main.c), e ancorar em outro (o exemplo oficial do C6 usa 0x30) deixaria a
 * imagem 90 graus fora em todas as posições.
 */
#pragma once

#include "driver/i2c_master.h"
#include "esp_err.h"
#include "lvgl.h"

#include "bsp/config.h"
#include "bsp/display.h"
#include "bsp/touch.h"

#ifdef __cplusplus
extern "C" {
#endif

#define BSP_I2C_NUM  (I2C_NUM_0)

/* Idempotente: chamar duas vezes devolve ESP_OK e o mesmo barramento. */
esp_err_t bsp_i2c_init(void);

/* NULL se o barramento ainda não subiu. */
i2c_master_bus_handle_t bsp_i2c_get_handle(void);

/* Mutex do LVGL. Assinatura mantida igual à do BSP oficial, com as duas
 * armadilhas que o main.c documenta: passe -1 para esperar indefinidamente
 * (com 0 o lock falha na hora e o LVGL roda sem proteção).
 *
 * Uma diferença deliberada: aqui true significa sucesso. O BSP oficial declara
 * bool mas devolve o esp_err_t do adapter, e como ESP_OK vale 0 o sucesso
 * chegava ao chamador como false. O firmware nunca testa o retorno — justamente
 * por causa desse bug —, então corrigir aqui não muda comportamento nenhum. */
bool bsp_display_lock(uint32_t timeout_ms);
void bsp_display_unlock(void);

#ifdef __cplusplus
}
#endif
