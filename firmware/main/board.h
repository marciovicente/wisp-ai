/* Perfil da placa — o único lugar do firmware que sabe QUAL placa é esta.
 *
 * POR QUE ESTE ARQUIVO EXISTE
 * ---------------------------
 * O firmware roda em duas placas irmãs: a ESP32-S3-Touch-AMOLED-2.16 e a
 * ESP32-C6-Touch-AMOLED-2.16. Elas têm o MESMO painel (CO5300 480x480), o mesmo
 * touch, a mesma IMU e o mesmo PMIC — e MCUs diferentes.
 *
 * Sem um lugar como este, cada diferença virava um `#if CONFIG_IDF_TARGET_*`
 * onde ela aparecia, espalhado por main.c e ui.c. O efeito colateral é o que
 * incomoda de verdade: mudanças de ESTILO acabavam presas ao chip, e a mesma
 * melhoria de interface tinha de ser feita duas vezes, ou só existia numa das
 * placas. Como a tela é idêntica nas duas, isso nunca foi necessário.
 *
 * A REGRA
 * -------
 * Aqui entra só o que é fato da PLACA: pinos, memória, como um sensor está
 * montado. Interface, layout, cores, tamanho de fonte — nada disso mora aqui,
 * porque nada disso depende do chip. Se você se pegar querendo acrescentar uma
 * medida de tela a este arquivo, o lugar dela é o ui.c, igual para as duas.
 *
 * Cada valor abaixo foi MEDIDO na placa correspondente, não lido de
 * documentação. Onde a documentação e a medição discordaram, quem ganhou foi a
 * medição — e está anotado.
 */
#pragma once

#include "driver/gpio.h"

#if CONFIG_IDF_TARGET_ESP32C6

#define BOARD_NOME              "ESP32-C6-Touch-AMOLED-2.16"

/* Sem PSRAM: o C6 não tem interface para ela. Consequências diretas — a pilha
 * da task do LVGL não pode ser pedida lá (a criação falharia e o display nunca
 * subiria), e o buffer de desenho já nasce onde o DMA lê, o que dispensa o
 * buffer de rebote que aperta o S3. */
#define BOARD_TEM_PSRAM         0

/* 40 linhas: 480*40*2 = 38KB, contra 127KB de RAM interna livres com o display
 * de pé. Mais alto que no S3 justamente por não haver PSRAM no caminho. */
#define BOARD_LVGL_LINHAS       40

/* Botões. O da direita é o GPIO10 e isso foi MEDIDO: toda a documentação desta
 * placa (a oficial e a nossa) põe o KEY no GPIO18, onde não existe botão algum
 * — o pino não se move. Achado varrendo os pinos livres em entrada com pull-up
 * e vendo qual desce sob o dedo.
 *
 * O do meio é o PWR e não é GPIO: chega como bit de interrupção no AXP2101. */
#define BOARD_BTN_BAIXO         GPIO_NUM_9    /* BOOT, esquerda */
#define BOARD_BTN_ALTO          GPIO_NUM_10   /* KEY, direita */
#define BOARD_BTN_MEIO_VIA_PMIC 1
#define BOARD_BTN_MEIO          GPIO_NUM_NC
#define BOARD_BTN_ATIVO         0             /* repousam em 1, descem ao apertar */
#define BOARD_BTN_MEIO_ATIVO    0             /* não se aplica: vem do PMIC */

/* A IMU é o mesmo QMI8658, montado em outra orientação: o eixo Y sai com sinal
 * oposto ao do S3. Sintoma de não tratar: as duas posições de lado trocadas
 * entre si, e como uma é a outra mais meia volta, as duas aparecem de cabeça
 * para baixo enquanto as verticais ficam certas. */
#define BOARD_IMU_Y_INVERTE     1

/* O módulo do painel está montado meia volta virado em relação ao do S3: com a
 * rotação já escolhendo o lado certo, as QUATRO posições apareciam invertidas,
 * todas pelo mesmo tanto. */
#define BOARD_PAINEL_MEIA_VOLTA 1

#else   /* ESP32-S3-Touch-AMOLED-2.16 */

#define BOARD_NOME              "ESP32-S3-Touch-AMOLED-2.16"

#define BOARD_TEM_PSRAM         1

/* 4 linhas, e o número é baixo por um motivo que não existe no C6: com o buffer
 * na PSRAM, cada flush paga um buffer de rebote em RAM interna alocado na hora,
 * e sob fragmentação essa alocação falha — flush que falha deixa o pixel velho
 * na tela, indistinguível de corrupção. Foi 16, depois 8, depois 4. */
#define BOARD_LVGL_LINHAS       4

/* Os três são GPIO nesta placa, e os pinos foram medidos: o BSP declara
 * BSP_CAPS_BUTTONS 0 e não documenta nenhum.
 *
 * ATENÇÃO à polaridade: as pontas repousam em 1 e descem ao apertar; o do meio
 * repousa em 0 e SOBE. Assumir "botão é ativo em nível baixo" funcionaria para
 * dois dos três. */
#define BOARD_BTN_BAIXO         GPIO_NUM_0    /* também é o pino de BOOT */
#define BOARD_BTN_ALTO          GPIO_NUM_18
#define BOARD_BTN_MEIO_VIA_PMIC 0
#define BOARD_BTN_MEIO          GPIO_NUM_16
#define BOARD_BTN_ATIVO         0
#define BOARD_BTN_MEIO_ATIVO    1

#define BOARD_IMU_Y_INVERTE     0
#define BOARD_PAINEL_MEIA_VOLTA 0

#endif
