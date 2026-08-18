/*
 * Fagulha — mascote de status do Claude Code
 * ESP32-S3-Touch-AMOLED-2.16 (480x480, CO5300 QSPI, touch CST9220)
 *
 * Fluxo: NVS (credenciais) -> WiFi -> mDNS resolve o Mac -> GET /state -> tela.
 *
 * As credenciais NUNCA aparecem no código: são gravadas direto na partição
 * NVS por bridge/provision_wifi.py, que pergunta a senha no terminal.
 */

#include <string.h>
#include <stdio.h>
#include <math.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "esp_log.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_http_client.h"
#include "esp_heap_caps.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "mdns.h"
#include "cJSON.h"
#include "lvgl.h"
#include "bsp/esp-bsp.h"
#include "bsp/display.h"
#include "bsp/touch.h"
#include "esp_lv_adapter.h"
#include "qmi8658.h"
#include "ui.h"

static const char *TAG = "fagulha";

#define NVS_NS        "fagulha"
#define PORTA_BRIDGE  4666
#define INTERVALO_MS  600      /* pausa entre consultas ao /state */
#define RESP_MAX      2048     /* /state mede ~290 bytes; folga de 7x */

static EventGroupHandle_t s_eventos;
#define BIT_CONECTADO BIT0
static char s_host[64] = {0};      /* ex.: "Marcios-MacBook-Pro-6.local" */
static char s_token[64] = {0};     /* segredo compartilhado com o bridge */
static char s_ip[16]   = {0};      /* resolvido por mDNS */
static fg_dados_t s_dados;
static esp_lcd_panel_handle_t s_painel = NULL;   /* guardado para rotacionar */
static esp_lcd_touch_handle_t s_toque = NULL;    /* idem: gira junto com a tela */

/* ————————————————————————————————————————————————
 *  Display
 *
 *  Não usamos bsp_display_start(): ele fixa buffer_height = 50, ou seja
 *  480*50*2 = 48KB por flush. Quando o comprimento da área não bate com o
 *  alinhamento de cache, o driver SPI aloca um buffer de rebote DESSE tamanho
 *  em RAM interna (spi_master.c: heap_caps_aligned_alloc). Sem WiFi sobravam
 *  135KB e cabia; com a pilha de rede sobram ~25KB e vira ESP_ERR_NO_MEM,
 *  travando o desenho.
 *
 *  Aqui reproduzimos a mesma sequência do BSP com buffer_height menor. O teto
 *  do rebote cai para 480*16*2 = 15KB. Custa mais flushes por quadro; em troca
 *  a tela volta a desenhar com a rede ligada.
 * ———————————————————————————————————————————————— */

/* 8 linhas.
 *
 * Era 16, medido estável quando o mascote era um corpo com dois olhos. Com o
 * rosto novo — pupilas, brilhos, sobrancelhas, boca e chama, oito objetos a
 * mais por mascote e até quatro mascotes — a RAM interna livre caiu e o
 * buffer de rebote do SPI passou a falhar: 15KB pedidos por flush contra
 * ~23KB livres e fragmentados. `Failed to allocate priv TX buffer`, e o
 * desenho simplesmente não acontece. Na tela isso aparece como uma coisa
 * sobre a outra, porque o pixel velho nunca é coberto — é fácil confundir
 * com bug de invalidação, e foi o que eu fiz por um tempo.
 *
 * Com 8 o rebote cai para 7,7KB, que cabe com folga. Custa mais flushes por
 * quadro; em troca o desenho volta a acontecer sempre. Desenho lento é
 * visível, desenho que falha é indistinguível de corrupção. */
/* 4 linhas.
 *
 * Foi 16, depois 8. Cai para 4 porque o buffer vive em RAM INTERNA e essa
 * memoria chegou a 180 BYTES de minimo historico com os mascotes de imagem —
 * territorio de estouro. Nao e teoria: a placa foi vista reiniciando sozinha,
 * e falta de RAM interna e a causa que sobra quando a rede esta boa e o
 * bridge responde.
 *
 * 480*4*2 = 3,8KB em vez de 7,7KB. Libera quase 4KB de um total que anda na
 * casa dos 10KB livres. Custa mais tiras por quadro, mas com imagem nao ha
 * animacao por quadro — a tela so redesenha quando o estado muda, e nessa
 * hora um pouco mais lento nao se percebe.
 *
 * Trocar velocidade que ninguem ve por estabilidade que todo mundo ve. */
#define ALTURA_BUFFER 4

/* O CO5300 exige áreas com início par e fim ímpar. Idêntico ao rounder do BSP.
 *
 * TENTADO E REVERTIDO: expandir para largura cheia (x1=0, x2=479) na teoria
 * eliminaria o buffer de rebote, porque len = 960*altura e 960 é múltiplo de
 * 64. Na prática o rebote continuou sendo alocado (o desalinhamento devia
 * estar no ENDEREÇO, não no comprimento) e cada piscada passou a redesenhar
 * uma faixa de 480px: FPS caiu de 66 para 8–26. Teoria bonita, medição
 * contrária — fica o registro para não tentarmos de novo. */
static void arredondar_area(lv_event_t *e)
{
    lv_area_t *a = (lv_area_t *) lv_event_get_param(e);
    a->x1 = (a->x1 >> 1) << 1;
    a->y1 = (a->y1 >> 1) << 1;
    a->x2 = ((a->x2 >> 1) << 1) + 1;
    a->y2 = ((a->y2 >> 1) << 1) + 1;
}

static lv_display_t *iniciar_display(void)
{
    bsp_display_cfg_t cfg = {
        .lv_adapter_cfg  = ESP_LV_ADAPTER_DEFAULT_CONFIG(),
        .rotation        = ESP_LV_ADAPTER_ROTATE_0,
        .tear_avoid_mode = ESP_LV_ADAPTER_TEAR_AVOID_MODE_NONE,
        /* Espelhamento do touch: copiado do bsp_display_start(). Errar isso
         * faz o toque cair no lugar errado da tela. */
        .touch_flags = {.swap_xy = 1, .mirror_x = 0, .mirror_y = 1},
    };
    /* A pilha da task do LVGL também sai da RAM interna. */
    cfg.lv_adapter_cfg.stack_in_psram = true;

    if (esp_lv_adapter_init(&cfg.lv_adapter_cfg) != ESP_OK) return NULL;

    esp_lcd_panel_handle_t painel = NULL;
    esp_lcd_panel_io_handle_t io = NULL;
    const bsp_display_config_t hw = {
        .max_transfer_sz = BSP_LCD_H_RES * ALTURA_BUFFER * 2,
    };
    if (bsp_display_new(&hw, &painel, &io) != ESP_OK) return NULL;
    s_painel = painel;   /* guardado para a rotação por hardware */

    esp_lv_adapter_display_config_t dcfg = {
        .panel = painel,
        .panel_io = io,
        .profile = {
            .interface             = ESP_LV_ADAPTER_PANEL_IF_OTHER,
            .rotation              = cfg.rotation,
            .hor_res               = BSP_LCD_H_RES,
            .ver_res               = BSP_LCD_V_RES,
            .buffer_height         = ALTURA_BUFFER,
            /* Buffer na RAM INTERNA, não na PSRAM.
             *
             * Com ele na PSRAM o driver SPI precisa copiar cada flush para um
             * buffer de rebote em RAM interna, alocado NA HORA. Sob a pressão
             * do rosto novo essa alocação passou a falhar em ~5% dos flushes
             * (`Failed to allocate priv TX buffer`), e flush que falha deixa
             * o pixel velho na tela — indistinguível de corrupção.
             *
             * Aqui o buffer nasce onde o DMA já pode ler: 480*8*2 = 7,7KB,
             * uma vez, no boot. Ou cabe e nunca mais falha, ou não sobe e a
             * gente sabe na hora. Buffer único pelo mesmo motivo — dois
             * dobrariam o custo fixo do recurso mais escasso da placa. */
            .use_psram             = false,
            .enable_ppa_accel      = false,
            .require_double_buffer = false,
        },
        .tear_avoid_mode = cfg.tear_avoid_mode,
    };
    lv_display_t *disp = esp_lv_adapter_register_display(&dcfg);
    if (!disp) return NULL;

    /* Rounder do CO5300: início par, fim ímpar. Copiado do BSP — sem isso o
     * painel recebe áreas desalinhadas e o desenho sai corrompido. */
    lv_display_add_event_cb(disp, arredondar_area, LV_EVENT_INVALIDATE_AREA, NULL);

    esp_lcd_touch_handle_t toque = NULL;
    if (bsp_touch_new(&cfg, &toque) == ESP_OK && toque) {
        s_toque = toque;   /* precisa girar junto com o painel */
        const esp_lv_adapter_touch_config_t tcfg =
            ESP_LV_ADAPTER_TOUCH_DEFAULT_CONFIG(disp, toque);
        esp_lv_adapter_register_touch(&tcfg);
    } else {
        ESP_LOGW(TAG, "touch não inicializou — segue sem swipe");
    }

    bsp_display_brightness_init();
    if (esp_lv_adapter_start() != ESP_OK) return NULL;
    return disp;
}

/* ————————————————————————————————————————————————
 *  Orientação (acelerômetro QMI8658)
 *
 *  A gravidade sempre aponta para baixo. Lendo em que eixo ela está mais
 *  forte descobrimos para que lado a placa está virada, e giramos a tela.
 *
 *  Com HISTERESE: exigimos a mesma leitura por ~1s antes de girar. Sem isso
 *  qualquer trepidação da mesa faria a tela virar sozinha.
 * ———————————————————————————————————————————————— */

static qmi8658_dev_t s_imu;
static bool s_imu_ok = false;

/* Rotação POR HARDWARE, via MADCTL do CO5300 (swap_xy + mirror).
 *
 * A rotação do LVGL não serve aqui: lv_display.c exige
 *   render_mode == DIRECT || render_mode == FULL
 * e nós rodamos em PARTIAL (buffer de 16 linhas) por causa da disputa de RAM
 * interna com o WiFi. lv_display_set_rotation() só logava um aviso e não
 * fazia nada — por isso a tela não girava.
 *
 * O painel girar sozinho é melhor de qualquer forma: custo zero de CPU,
 * nenhum buffer extra. E como a tela é QUADRADA (480x480), girar não muda
 * as dimensões, que é o que normalmente complica esse caminho.
 */
/*
 * ANCORADO NA ORIENTAÇÃO REAL DO PAINEL, não em 0x00.
 *
 * A sequência de init do BSP manda {0x36, 0xA0} — MADCTL = 1010 0000, ou seja
 * MY=1, MX=0, MV=1. O painel é montado girado nesta placa, e 0xA0 é a posição
 * natural, não 0x00.
 *
 * Meu primeiro palpite usava 0x00 como "0 grau". Resultado: o caso 0 não
 * voltava ao natural, apagava a base do BSP — e a tela ficava errada em TODAS
 * as posições depois da primeira virada. Antes de girar parecia certa só
 * porque eu ainda não tinha sobrescrito nada.
 *
 * Ciclo padrão de 90 em 90 no MADCTL:  0x00 -> 0x60 -> 0xC0 -> 0xA0 -> 0x00
 *
 * Achado por medição, em três passos:
 *   1. Ancorado em 0xA0 (o valor que o BSP escreve): imagem 90 graus fora,
 *      apontando para a esquerda em TODAS as posições. Erro constante como
 *      esse é a tabela inteira deslocada, não bug por posição.
 *   2. Deslocado um passo para 0x00: ficou 180 graus fora. Ou seja, andei
 *      para o lado errado do ciclo e acumulei mais 90.
 *   3. Dois passos de volta a partir dali = começar em 0xC0. É esta tabela.
 *
 * Bits: MV = swap_xy (bit5), MX = mirror_x (bit6), MY = mirror_y (bit7).
 */
static void aplicar_rotacao(int graus)
{
    if (!s_painel) return;
    bool swap, mx, my;
    switch (graus) {
        case 90:  swap = true;  mx = false; my = true;  break;  /* 0xA0 */
        case 180: swap = false; mx = false; my = false; break;  /* 0x00 */
        case 270: swap = true;  mx = true;  my = false; break;  /* 0x60 */
        default:  swap = false; mx = true;  my = true;  break;  /* 0xC0 */
    }
    esp_lcd_panel_swap_xy(s_painel, swap);
    esp_lcd_panel_mirror(s_painel, mx, my);

    /* O TOUCH TEM DE GIRAR JUNTO.
     *
     * Girar so o painel deixa as coordenadas do dedo no referencial antigo:
     * um arrasto horizontal na tela chega ao LVGL como vertical, e o
     * tileview — que so rola na horizontal — simplesmente ignora. Era por
     * isso que o deslize para o painel de limites tinha parado de funcionar
     * depois que a rotacao automatica entrou.
     *
     * Os flags que o BSP passa ao touch (swap_xy=1, mirror_x=0, mirror_y=1)
     * sao exatamente os bits do MADCTL base (0xA0), entao a mesma tripla
     * serve para os dois. */
    if (s_toque) {
        esp_lcd_touch_set_swap_xy(s_toque, swap);
        esp_lcd_touch_set_mirror_x(s_toque, mx);
        esp_lcd_touch_set_mirror_y(s_toque, my);
    }
}

static bool iniciar_imu(void)
{
    i2c_master_bus_handle_t bus = bsp_i2c_get_handle();
    if (!bus) {
        ESP_LOGW(TAG, "sem barramento I2C — sem rotação automática");
        return false;
    }
    /* O endereço depende de como o pino SA0 está amarrado; tentamos os dois
     * em vez de assumir. */
    if (qmi8658_init(&s_imu, bus, QMI8658_ADDRESS_LOW) != ESP_OK &&
        qmi8658_init(&s_imu, bus, QMI8658_ADDRESS_HIGH) != ESP_OK) {
        ESP_LOGW(TAG, "QMI8658 não respondeu — sem rotação automática");
        return false;
    }
    qmi8658_enable_accel(&s_imu, true);
    /* O header declara qmi8658_read_accel_mps2(), mas o componente nunca a
     * implementa — dá erro de link. A conversão real mora em
     * qmi8658_read_accel(), que consulta esta flag. */
    s_imu.accel_unit_mps2 = true;
    ESP_LOGI(TAG, "IMU pronto");
    return true;
}

static void tarefa_orientacao(void *arg)
{
    (void) arg;
    lv_display_rotation_t atual = LV_DISPLAY_ROTATION_0, candidata = atual;
    int estavel = 0, voltas = 0;

    /* ~0.4g: exige a placa claramente inclinada, não um encostão. */
    const float LIMIAR = 4.0f;

    /* O sensor cospe lixo nas primeiras transações (o próprio init loga
     * "Failed to read WHO_AM_I"). Sem esperar, as 4 primeiras leituras
     * ruins passavam pela histerese e travavam a tela numa rotação errada
     * — de onde ela nunca mais saía, porque deitada na mesa nenhum eixo
     * ultrapassa o limiar para corrigir. */
    vTaskDelay(pdMS_TO_TICKS(1500));

    while (1) {
        float x = 0, y = 0, z = 0;
        if (qmi8658_read_accel(&s_imu, &x, &y, &z) == ESP_OK) {
            /* Sanidade: em repouso o vetor tem de valer ~9.8 m/s². Fora
             * dessa faixa é ruído de barramento ou a placa em movimento
             * brusco — em ambos os casos não serve para decidir orientação. */
            float mag = sqrtf(x * x + y * y + z * z);
            if (mag < 7.0f || mag > 12.5f) {
                vTaskDelay(pdMS_TO_TICKS(250));
                continue;
            }
            /* Mapeamento medido na placa, não deduzido do datasheet:
             * em pé com a tela voltada para quem olha, a leitura é
             * x = -9.5, y = 0, z = 0. Ou seja, o eixo X do sensor aponta
             * para CIMA na tela, e a gravidade cai nele em negativo.
             * Logo -X = posição natural = sem rotação.
             *
             * O sinal de Y (qual lado é 90 e qual é 270) não deu para medir
             * pela serial — girar a placa mexe no cabo USB que carrega o
             * log. Foi resolvido testando na mão: o primeiro palpite girava
             * para o lado errado na horizontal (o vertical já estava certo),
             * então 90 e 270 estão invertidos em relação ao que eu supus. */
            lv_display_rotation_t nova = atual;
            if (fabsf(x) > fabsf(y)) {
                if (fabsf(x) > LIMIAR)
                    nova = (x < 0) ? LV_DISPLAY_ROTATION_0 : LV_DISPLAY_ROTATION_180;
            } else {
                if (fabsf(y) > LIMIAR)
                    nova = (y < 0) ? LV_DISPLAY_ROTATION_270 : LV_DISPLAY_ROTATION_90;
            }

            /* PRIMEIRA leitura válida: aplica na hora, sem histerese.
             *
             * No boot o painel está com o MADCTL que o BSP escreveu (0xA0),
             * que não corresponde a nenhuma entrada da nossa tabela. Sem isto
             * a tela só se alinhava depois da primeira virada — o sintoma de
             * "ao reiniciar volta sempre para a mesma posição". Agora ela
             * nasce na orientação em que a placa realmente está, seja ela
             * qual for. */
            static bool ja_aplicou = false;
            if (!ja_aplicou) {
                ja_aplicou = true;
                atual = candidata = nova;
                estavel = 0;
                bsp_display_lock(-1);
                aplicar_rotacao((int) atual * 90);
                lv_obj_invalidate(lv_screen_active());
                bsp_display_unlock();
                ESP_LOGI(TAG, "orientacao inicial: %d graus", (int) atual * 90);
            } else if (nova != candidata) {
                candidata = nova;
                estavel = 0;
            } else if (++estavel == 4 && nova != atual) {   /* 4 x 250ms = 1s */
                atual = nova;
                bsp_display_lock(-1);
                aplicar_rotacao((int) atual * 90);
                lv_obj_invalidate(lv_screen_active());   /* redesenha tudo */
                bsp_display_unlock();
                ESP_LOGI(TAG, "girou para %d graus", (int) atual * 90);
            }

            /* Log periódico dos eixos: é assim que se calibra qual eixo é
             * qual, em vez de adivinhar a montagem do sensor na placa. */
            if (++voltas % 12 == 0) {
                ESP_LOGI(TAG, "accel x=%.1f y=%.1f z=%.1f  (rot=%d)",
                         x, y, z, (int) atual * 90);
            }
        }
        vTaskDelay(pdMS_TO_TICKS(250));
    }
}

/* ————————————————————————————————————————————————
 *  WiFi
 * ———————————————————————————————————————————————— */

static void ao_evento(void *arg, esp_event_base_t base, int32_t id, void *dados)
{
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        xEventGroupClearBits(s_eventos, BIT_CONECTADO);
        ESP_LOGW(TAG, "WiFi caiu, reconectando");
        s_ip[0] = '\0';                 /* força resolver mDNS de novo */
        vTaskDelay(pdMS_TO_TICKS(2000));
        esp_wifi_connect();
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e = (ip_event_got_ip_t *) dados;
        ESP_LOGI(TAG, "IP obtido: " IPSTR, IP2STR(&e->ip_info.ip));
        xEventGroupSetBits(s_eventos, BIT_CONECTADO);
    }
}

static bool ler_credenciais(char *ssid, size_t ssid_n, char *senha, size_t senha_n)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) {
        ESP_LOGW(TAG, "namespace '%s' não existe na NVS", NVS_NS);
        return false;
    }
    bool ok = nvs_get_str(h, "ssid", ssid, &ssid_n) == ESP_OK
           && nvs_get_str(h, "pass", senha, &senha_n) == ESP_OK;

    size_t tn = sizeof(s_token);
    if (nvs_get_str(h, "token", s_token, &tn) != ESP_OK) {
        s_token[0] = '\0';   /* placa gravada antes do token existir */
    }

    size_t hn = sizeof(s_host);
    if (nvs_get_str(h, "host", s_host, &hn) != ESP_OK) {
        s_host[0] = '\0';
    }
    nvs_close(h);
    return ok;
}

static bool iniciar_wifi(void)
{
    char ssid[33] = {0}, senha[65] = {0};
    if (!ler_credenciais(ssid, sizeof(ssid), senha, sizeof(senha))) {
        return false;
    }
    ESP_LOGI(TAG, "conectando em '%s' (host do bridge: '%s')", ssid, s_host);

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    /* SEM ESP_ERROR_CHECK aqui: ele aborta, e abortar no boot vira boot loop
     * eterno. O WiFi disputa RAM interna com o buffer do display; se perder,
     * o certo é seguir sem rede mostrando o estado na tela, não reiniciar
     * para sempre. (Aconteceu de verdade ao subir o buffer para 60 linhas:
     * "esf_buf_setup_static: alloc eb fail" -> ESP_ERR_NO_MEM -> loop.) */
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_err_t r = esp_wifi_init(&cfg);
    if (r != ESP_OK) {
        ESP_LOGE(TAG, "esp_wifi_init falhou: %s (interna livre: %u) — seguindo sem rede",
                 esp_err_to_name(r),
                 (unsigned) heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
        return false;
    }
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &ao_evento, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &ao_evento, NULL));

    /* snprintf em vez de strncpy: sempre termina em NUL e não dispara o
     * -Werror=stringop-truncation do ESP-IDF 5.5 (o campo de senha tem 64
     * bytes e nosso buffer local, 65 — o strncpy defensivo virava erro). */
    wifi_config_t wc = {0};
    snprintf((char *) wc.sta.ssid, sizeof(wc.sta.ssid), "%s", ssid);
    snprintf((char *) wc.sta.password, sizeof(wc.sta.password), "%s", senha);

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wc));
    ESP_ERROR_CHECK(esp_wifi_start());
    return true;
}

/* ————————————————————————————————————————————————
 *  Descoberta do bridge
 * ———————————————————————————————————————————————— */

/* Descobre onde esta o bridge.
 *
 * PRIMEIRO por SERVICO mDNS (_fagulha._tcp), depois pelo hostname gravado na
 * NVS como reserva.
 *
 * Motivo: o macOS deriva o LocalHostName do ComputerName e acrescenta "-N"
 * sempre que detecta conflito de nome na rede. Neste Mac ja aconteceu 7 vezes.
 * Quando ele virou "-7", o nome "Marcios-MacBook-Pro-6.local" gravado aqui
 * simplesmente deixou de existir e a placa ficou orfa. O nome do SERVICO nao
 * muda, e o proprio macOS mantem o endereco atualizado quando o DHCP troca. */
static bool resolver_host(void)
{
    mdns_result_t *r = NULL;
    if (mdns_query_ptr("_fagulha", "_tcp", 3000, 4, &r) == ESP_OK && r) {
        for (mdns_result_t *it = r; it; it = it->next) {
            if (it->addr) {
                esp_ip4_addr_t a = it->addr->addr.u_addr.ip4;
                snprintf(s_ip, sizeof(s_ip), IPSTR, IP2STR(&a));
                ESP_LOGI(TAG, "bridge achado pelo servico mDNS -> %s", s_ip);
                mdns_query_results_free(r);
                return true;
            }
        }
        mdns_query_results_free(r);
    }

    /* Reserva: hostname da NVS, para quem nao tiver o anuncio de pe. */
    if (s_host[0] == '\0') return false;
    char nome[64];
    snprintf(nome, sizeof(nome), "%s", s_host);
    char *ponto = strstr(nome, ".local");
    if (ponto) *ponto = '\0';

    esp_ip4_addr_t addr = {0};
    esp_err_t e = mdns_query_a(nome, 3000, &addr);
    if (e != ESP_OK) {
        ESP_LOGW(TAG, "nem servico nem host '%s': %s", nome, esp_err_to_name(e));
        return false;
    }
    snprintf(s_ip, sizeof(s_ip), IPSTR, IP2STR(&addr));
    ESP_LOGI(TAG, "bridge achado pelo hostname -> %s", s_ip);
    return true;
}

/* ————————————————————————————————————————————————
 *  HTTP + JSON
 * ———————————————————————————————————————————————— */

typedef struct { char *buf; int usado; } coleta_t;

static esp_err_t ao_http(esp_http_client_event_t *e)
{
    if (e->event_id != HTTP_EVENT_ON_DATA) return ESP_OK;
    coleta_t *c = (coleta_t *) e->user_data;
    if (!c || !c->buf) return ESP_OK;
    int cabe = RESP_MAX - 1 - c->usado;
    int n = e->data_len < cabe ? e->data_len : cabe;
    if (n > 0) {
        memcpy(c->buf + c->usado, e->data, n);
        c->usado += n;
        c->buf[c->usado] = '\0';
    }
    return ESP_OK;
}

static void copiar_str(char *dst, size_t n, const cJSON *o, const char *chave)
{
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, chave);
    if (cJSON_IsString(v) && v->valuestring) {
        strncpy(dst, v->valuestring, n - 1);
        dst[n - 1] = '\0';
    } else {
        dst[0] = '\0';
    }
}

static bool interpretar(const char *json, fg_dados_t *d)
{
    cJSON *raiz = cJSON_Parse(json);
    if (!raiz) return false;

    /* Uma sessao do Claude = um mascote. O bridge manda em "s", mais
     * recentes primeiro, ja limitado a FG_MAX_SESSOES. */
    d->qtd_sessoes = 0;
    const cJSON *ses = cJSON_GetObjectItemCaseSensitive(raiz, "s"), *it_s = NULL;
    cJSON_ArrayForEach(it_s, ses) {
        if (d->qtd_sessoes >= FG_MAX_SESSOES) break;
        fg_sessao_t *sx = &d->sessoes[d->qtd_sessoes];
        char st[16];
        copiar_str(st, sizeof(st), it_s, "st");
        sx->estado = ui_estado_de_texto(st);
        copiar_str(sx->detalhe, sizeof(sx->detalhe), it_s, "dt");
        copiar_str(sx->projeto, sizeof(sx->projeto), it_s, "pj");
        copiar_str(sx->modelo,  sizeof(sx->modelo),  it_s, "md");
        const cJSON *a = cJSON_GetObjectItemCaseSensitive(it_s, "age");
        sx->idade_s = cJSON_IsNumber(a) ? a->valueint : -1;
        d->qtd_sessoes++;
    }
    /* qtd_sessoes == 0 e um estado VALIDO: nenhuma sessao ativa. A UI
     * interpreta isso como "mostre o relogio". Nao inventamos uma sessao
     * fantasma aqui. */

    const cJSON *idade = cJSON_GetObjectItemCaseSensitive(raiz, "lim_age");
    d->limites_idade_s = cJSON_IsNumber(idade) ? idade->valueint : -1;

    /* —— modo repouso: relógio e tempo —— */
    copiar_str(d->hora, sizeof(d->hora), raiz, "clk");
    copiar_str(d->dia,  sizeof(d->dia),  raiz, "day");
    const cJSON *n;
    n = cJSON_GetObjectItemCaseSensitive(raiz, "age");
    d->idade_s = cJSON_IsNumber(n) ? n->valueint : -1;
    n = cJSON_GetObjectItemCaseSensitive(raiz, "rest");
    d->repouso_s = cJSON_IsNumber(n) ? n->valueint : 0;

    d->tem_tempo = false;
    const cJSON *wx = cJSON_GetObjectItemCaseSensitive(raiz, "wx");
    if (cJSON_IsObject(wx)) {
        copiar_str(d->condicao, sizeof(d->condicao), wx, "c");
        copiar_str(d->icone,    sizeof(d->icone),    wx, "i");
        n = cJSON_GetObjectItemCaseSensitive(wx, "t");
        d->temp = cJSON_IsNumber(n) ? n->valueint : 0;
        n = cJSON_GetObjectItemCaseSensitive(wx, "hi");
        d->temp_max = cJSON_IsNumber(n) ? n->valueint : 0;
        n = cJSON_GetObjectItemCaseSensitive(wx, "lo");
        d->temp_min = cJSON_IsNumber(n) ? n->valueint : 0;
        d->tem_tempo = d->condicao[0] != '\0';
    }

    d->qtd_limites = 0;
    const cJSON *lim = cJSON_GetObjectItemCaseSensitive(raiz, "lim"), *it = NULL;
    cJSON_ArrayForEach(it, lim) {
        if (d->qtd_limites >= 4) break;
        fg_limite_t *b = &d->limites[d->qtd_limites];
        copiar_str(b->rotulo,    sizeof(b->rotulo),    it, "l");
        copiar_str(b->reseta,    sizeof(b->reseta),    it, "r");
        copiar_str(b->gravidade, sizeof(b->gravidade), it, "s");
        const cJSON *p = cJSON_GetObjectItemCaseSensitive(it, "p");
        b->pct = cJSON_IsNumber(p) ? p->valueint : 0;
        b->ativo = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(it, "a"));
        d->qtd_limites++;
    }

    cJSON_Delete(raiz);
    return true;
}

static void tarefa_rede(void *arg)
{
    char *buf = heap_caps_malloc(RESP_MAX, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!buf) buf = malloc(RESP_MAX);
    char url[96];
    int falhas = 0, voltas = 0;

    while (1) {
        xEventGroupWaitBits(s_eventos, BIT_CONECTADO, pdFALSE, pdTRUE, portMAX_DELAY);

        if (s_ip[0] == '\0' && !resolver_host()) {
            /* Antes isto so dava `continue` e a tela ficava eternamente em
             * "connecting" — mentindo, porque o WiFi ja estava conectado e o
             * que faltava era achar o bridge. Agora a tela diz a verdade. */
            fg_dados_t nd = {.qtd_sessoes = 1, .limites_idade_s = -1};
            nd.sessoes[0].estado = FG_SEM_REDE;
            snprintf(nd.sessoes[0].detalhe, sizeof(nd.sessoes[0].detalhe),
                     "bridge not found");
            ui_atualizar(&nd);
            vTaskDelay(pdMS_TO_TICKS(5000));
            continue;
        }

        snprintf(url, sizeof(url), "http://%s:%d/state", s_ip, PORTA_BRIDGE);
        coleta_t c = {.buf = buf, .usado = 0};
        esp_http_client_config_t cfg = {
            .url = url, .event_handler = ao_http, .user_data = &c,
            .timeout_ms = 2500, .method = HTTP_METHOD_GET,
        };
        esp_http_client_handle_t cli = esp_http_client_init(&cfg);
        /* O bridge escuta na rede local para nos alcançar, e por isso serve
         * nomes de projeto e consumo a quem pedir. O token fecha isso: sem
         * ele, quem estiver na mesma rede — coworking, café — leria tudo só
         * apontando o navegador. Gravado na NVS junto com o WiFi.
         *
         * Vazio é legítimo: instalação com `exigir_token: false`, que existe
         * para placas gravadas antes deste campo. Aí não mandamos header. */
        if (s_token[0]) {
            esp_http_client_set_header(cli, "X-Fagulha-Token", s_token);
        }
        esp_err_t r = esp_http_client_perform(cli);
        int status = esp_http_client_get_status_code(cli);
        esp_http_client_cleanup(cli);

        if (r == ESP_OK && status == 200 && c.usado > 0) {
            falhas = 0;
            if (interpretar(buf, &s_dados)) {
                ui_atualizar(&s_dados);
            }
        } else if (++falhas == 5) {
            /* Cinco erros seguidos: o bridge caiu ou o IP mudou.
             * Zera o IP para forçar nova resolução mDNS na volta. */
            ESP_LOGW(TAG, "bridge inacessível (%s, status %d)", esp_err_to_name(r), status);
            s_ip[0] = '\0';
            fg_dados_t off = {.qtd_sessoes = 1, .limites_idade_s = -1};
            off.sessoes[0].estado = FG_SEM_REDE;
            snprintf(off.sessoes[0].detalhe, sizeof(off.sessoes[0].detalhe),
                     "bridge offline");
            ui_atualizar(&off);
        }

        /* A RAM interna é o recurso disputado entre a pilha WiFi e o buffer
         * DMA do display. Reportar periodicamente para flagrar vazamento ou
         * aperto antes que vire "Draw bitmap failed". */
        if (++voltas % 25 == 0) {
            ESP_LOGI(TAG, "interna livre: %u (mín histórico %u) | PSRAM: %u",
                     (unsigned) heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
                     (unsigned) heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL),
                     (unsigned) heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
        }

        vTaskDelay(pdMS_TO_TICKS(INTERVALO_MS));
    }
}

/* ————————————————————————————————————————————————
 *  app_main
 * ———————————————————————————————————————————————— */

void app_main(void)
{
    esp_err_t nv = nvs_flash_init();
    if (nv == ESP_ERR_NVS_NO_FREE_PAGES || nv == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        nv = nvs_flash_init();
    }
    ESP_ERROR_CHECK(nv);

    ESP_LOGI(TAG, "iniciando display (buffer de %d linhas)", ALTURA_BUFFER);
    if (!iniciar_display()) {
        ESP_LOGE(TAG, "display não inicializou");
        return;
    }

    /* ARMADILHA, duas na verdade — o header do BSP mente sobre as duas:
     *
     * 1. Ele documenta "0 will block indefinitely", mas só encaminha para
     *    esp_lv_adapter_lock(), cujo header diz "use -1 for infinite wait".
     *    Com 0 o lock falha na hora, o LVGL é chamado sem proteção, corre com
     *    a task de render e dispara LV_ASSERT_MSG("Invalidate area is not
     *    allowed during rendering") — que é um while(1). Vira watchdog.
     *
     * 2. O BSP declara retorno `bool`, mas devolve o esp_err_t do adapter.
     *    Como ESP_OK vale 0, o sucesso converte para `false`. Testar
     *    `if (bsp_display_lock(-1))` estaria invertido. Por isso não testo.
     */
    bsp_display_lock(-1);
    ui_criar();
    bsp_display_unlock();

    /* IMU depois do display: o BSP cria o barramento I2C durante o
     * bsp_touch_new(), então bsp_i2c_get_handle() só é válido a partir daqui. */
    s_imu_ok = iniciar_imu();
    if (s_imu_ok) {
        xTaskCreate(tarefa_orientacao, "orient", 3072, NULL, 3, NULL);
    }

    s_eventos = xEventGroupCreate();

    memset(&s_dados, 0, sizeof(s_dados));
    s_dados.qtd_sessoes = 1;
    s_dados.sessoes[0].estado = FG_SEM_REDE;
    s_dados.limites_idade_s = -1;
    s_dados.bateria_pct = -1;

    if (!iniciar_wifi()) {
        ESP_LOGE(TAG, "sem credenciais na NVS — rode bridge/provision_wifi.py");
        snprintf(s_dados.sessoes[0].detalhe, sizeof(s_dados.sessoes[0].detalhe), "no wifi setup");
        ui_atualizar(&s_dados);
    } else {
        snprintf(s_dados.sessoes[0].detalhe, sizeof(s_dados.sessoes[0].detalhe), "connecting");
        ui_atualizar(&s_dados);
        ESP_ERROR_CHECK(mdns_init());
        xTaskCreate(tarefa_rede, "rede", 6144, NULL, 5, NULL);
    }

    ESP_LOGI(TAG, "PSRAM livre: %u | RAM interna: %u",
             (unsigned) heap_caps_get_free_size(MALLOC_CAP_SPIRAM),
             (unsigned) heap_caps_get_free_size(MALLOC_CAP_INTERNAL));

    while (1) vTaskDelay(pdMS_TO_TICKS(10000));
}
