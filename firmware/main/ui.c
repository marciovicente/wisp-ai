/*
 * Fagulha — desenho e animação.
 *
 * Três modos na mesma tela (tile 0):
 *   1. mascotes  — um por sessão do Claude, 1 a 4, dividindo o espaço
 *   2. repouso   — relógio + tempo, quando tudo está ocioso há tempo
 *   3. limites   — segunda página, acessível deslizando (tile 1)
 *
 * A rede só define o ESTADO ALVO. Um lv_timer interpola a cada quadro, então
 * nenhuma troca corta. O timer roda dentro da task do LVGL, que JÁ segura o
 * mutex — chamar bsp_display_lock() lá dentro seria deadlock.
 */

#include <string.h>
#include <stdio.h>
#include <math.h>
#include "esp_log.h"
#include "lvgl.h"
#include "bsp/esp-bsp.h"
#include "esp_mmap_assets.h"
#include "esp_lv_decoder.h"
#include "ui.h"

static const char *TAG = "ui";

/* ————————————————————————————————————————————————
 *  Mascotes de imagem, vindos da particao `storage`
 *
 *  Os PNG sao empacotados no build e ficam MAPEADOS na flash — o ponteiro
 *  aponta direto para os bytes, sem copia para a RAM. Isso importa muito
 *  aqui: a RAM interna e o recurso mais escasso desta placa, e ja chegou a
 *  4,7KB de minimo historico.
 *
 *  O componente desta versao NAO gera o cabecalho mmap_generate_*.h, entao
 *  `checksum` e `files` saem lidos do proprio binario (offsets 0x10 e 0x0C do
 *  cabecalho de 32 bytes) e os assets sao acessados por indice, em ordem
 *  alfabetica.
 * ———————————————————————————————————————————————— */
#define ASSETS_QTD      8
#define ASSETS_CHECKSUM 14708

/* Ordem alfabetica dos arquivos na particao, mapeada para os nossos estados. */
static const int IDX[FG_QTD] = {
    [FG_OCIOSO]      = 3,   /* idle    */
    [FG_TRABALHANDO] = 7,   /* working */
    [FG_FERRAMENTA]  = 5,   /* tool    */
    [FG_PERGUNTANDO] = 0,   /* asking  */
    [FG_ESPERANDO]   = 6,   /* waiting */
    [FG_CONCLUIDO]   = 1,   /* done    */
    [FG_ERRO]        = 2,   /* error   */
    [FG_SEM_REDE]    = 4,   /* offline */
};

static mmap_assets_handle_t s_assets;
static lv_image_dsc_t s_dsc[FG_QTD];
static bool s_tem_fotos = false;

static void carregar_fotos(void)
{
    esp_lv_decoder_handle_t dec = NULL;
    if (esp_lv_decoder_init(&dec) != ESP_OK) {
        ESP_LOGW(TAG, "decoder nao subiu — segue no vetor");
        return;
    }
    const mmap_assets_config_t cfg = {
        .partition_label = "storage",
        .max_files = ASSETS_QTD,
        .checksum = ASSETS_CHECKSUM,
        .flags = {.mmap_enable = true},
    };
    if (mmap_assets_new(&cfg, &s_assets) != ESP_OK) {
        ESP_LOGW(TAG, "particao de mascotes nao abriu — segue no vetor");
        return;
    }
    for (int e = 0; e < FG_QTD; e++) {
        int i = IDX[e];
        const uint8_t *dados = mmap_assets_get_mem(s_assets, i);
        int tam = mmap_assets_get_size(s_assets, i);
        if (!dados || tam <= 0) return;
        s_dsc[e].header.magic = LV_IMAGE_HEADER_MAGIC;
        /* RGB565A8 CRU, convertido no build. Sem decodificacao: o LVGL le
         * direto da flash mapeada.
         *
         * A primeira versao usava RAW_ALPHA, que decodifica PNG em tempo de
         * execucao. Medido: FPS caiu de 62 para 1-7 e a RAM interna chegou a
         * 12 bytes de minimo historico. Nesta placa nao ha folga para
         * decodificar imagem — a conversao tem que acontecer antes. */
        s_dsc[e].header.cf = LV_COLOR_FORMAT_RGB565A8;
        s_dsc[e].header.w = 236;
        s_dsc[e].header.h = 236;
        s_dsc[e].header.stride = 236 * 2;
        s_dsc[e].data = dados;
        s_dsc[e].data_size = tam;
    }
    s_tem_fotos = true;
    ESP_LOGI(TAG, "mascotes de imagem carregados (%d estados)", FG_QTD);
}

/* 16ms para acompanhar o refresh do LVGL (LV_DEF_REFR_PERIOD=15). Com 33ms a
 * fagulha só se movia em metade dos quadros e parecia travada. */
#define PERIODO_MS 16
#define QTD_INTERROG 3
#define PISCADA_MS 170

/* ——— paleta por estado ——— */
typedef struct { uint8_t r, g, b, dr, dg, db; } cor_t;

/* O corpo do computador nao muda de cor — quem muda e a TELA, como num
 * monitor de verdade. Isso e mais fiel ao personagem e mais legivel: a cor
 * chega como LUZ vindo de dentro, nao como o boneco inteiro trocando de
 * tinta. */
#define C_CARCACA_T lv_color_make(238, 230, 210)
#define C_CARCACA_B lv_color_make(206, 194, 172)

static const cor_t COR[FG_QTD] = {
    [FG_OCIOSO]      = {232, 132,  90, 176,  78,  52},
    [FG_TRABALHANDO] = {232, 132,  90, 176,  78,  52},
    [FG_FERRAMENTA]  = {232, 152,  82, 172,  96,  44},
    [FG_PERGUNTANDO] = {186, 142, 234, 122,  84, 172},
    [FG_ESPERANDO]   = {232, 193,  90, 168, 132,  48},
    [FG_CONCLUIDO]   = { 95, 207, 142,  52, 132,  90},
    [FG_ERRO]        = { 96, 150, 205,  58,  96, 140},
    [FG_SEM_REDE]    = { 90,  99, 112,  52,  58,  68},
};

/* Texto EXIBIDO em inglês: as Montserrat do LVGL não têm acento. */
static const char *NOME[FG_QTD] = {
    [FG_OCIOSO] = "idle",        [FG_TRABALHANDO] = "thinking",
    [FG_FERRAMENTA] = "working", [FG_PERGUNTANDO] = "asking you",
    [FG_ESPERANDO] = "needs you",[FG_CONCLUIDO] = "done",
    [FG_ERRO] = "failed",        [FG_SEM_REDE] = "offline",
};

/* Alvos por estado. As medidas do olho são para o mascote em tamanho cheio;
 * com várias sessões elas são escaladas proporcionalmente. */
/* Bocas. A curvatura e o que separa contentamento de aflicao. */
typedef enum { BOCA_SORRISO, BOCA_SORRISAO, BOCA_PEQUENA, BOCA_O,
               BOCA_RETA, BOCA_ONDA } boca_t;

typedef struct {
    int16_t olho_alt, olho_dx, olho_dy;
    uint8_t respira;
    uint8_t orbita;      /* 0 = fagulha parada, 255 = órbita rápida */
    bool    interrog;
    /* —— expressao ——
     * sobrancelha: angulo em graus. Positivo levanta a ponta EXTERNA, que le
     * como surpresa; negativo abaixa, que le como concentracao. Com
     * `sob_invertida` quem sobe e a ponta INTERNA — e essa e a diferenca
     * entre parecer bravo e parecer preocupado. */
    int16_t sob_ang;
    int16_t sob_dy;
    bool    sob_invertida;
    boca_t  boca;
    int16_t olhar_x, olhar_y;   /* direcao da pupila, -100 a 100 */
    bool    olhos_felizes;      /* arcos para cima, o sorriso que mora no olho */
} alvo_t;

static const alvo_t ALVO[FG_QTD] = {
    /*                 alt  dx   dy  resp orb interr | sob_ang dy inv | boca         olhar_x y | felizes */
    [FG_OCIOSO]      = {40,  0,  -6,  6,  20, false,        0,  0, false, BOCA_SORRISO,   0,   0, false},
    [FG_TRABALHANDO] = {36,  0,  -2,  4, 170, false,       -6,  4, false, BOCA_PEQUENA,  45, -50, false},
    [FG_FERRAMENTA]  = {24, -4,   4,  3, 255, false,      -16, -5, false, BOCA_PEQUENA,   0,  15, false},
    [FG_PERGUNTANDO] = {46,  0,  -9,  7,   0, true,        14, 10, false, BOCA_O,         0, -10, false},
    [FG_ESPERANDO]   = {44,  0,  -8, 10,  60, false,       20,  8, false, BOCA_ONDA,      0,  10, false},
    [FG_CONCLUIDO]   = {12,  0,  -2,  9,  40, false,        8,  6, false, BOCA_SORRISAO,  0,   0, true },
    [FG_ERRO]        = {32,  0,   6,  3,  25, false,      -22,  2, true,  BOCA_ONDA,      0,  25, false},
    [FG_SEM_REDE]    = { 8,  0,   0,  2,   0, false,        0, -3, false, BOCA_RETA,      0,   0, false},
};

/* ————————————————————————————————————————————————
 *  Um mascote = uma sessão do Claude
 * ———————————————————————————————————————————————— */
typedef struct {
    lv_obj_t *corpo, *olho[2], *fagulha, *detalhe, *projeto;
    /* Rosto: o que estava faltando para os oito estados nao serem o mesmo
     * boneco em oito cores. Olho vira BRANCO com pupila e brilho; sobrancelha
     * e boca entram porque e nelas que a expressao mora. */
    lv_obj_t *pupila[2], *brilho[2], *sobrancelha[2], *boca, *chama;
    lv_obj_t *tela, *braco[2];       /* carcaca de computador */
    lv_obj_t *moldura, *luz, *scan[2], *topo;  /* profundidade */
    lv_obj_t *foto;          /* mascote de imagem; NULL = desenhado */
    int16_t p_boca, p_esc;   /* guardas do rosto: estado e escala */
    /* Pontos da sobrancelha. lv_line guarda o PONTEIRO, nao copia — se este
     * array sair de escopo, o LVGL desenha lixo. Por isso vive aqui. */
    lv_point_precise_t sob_pts[2][2];
    fg_estado_t alvo, anterior;
    int16_t olho_alt, olho_dx, olho_dy;
    int16_t p_alt, p_dx, p_dy;          /* guardas: só redesenha se mudou */
    float   ang, vel;                    /* órbita acumulada da fagulha */
    uint32_t prox_piscada, inicio_piscada;
    int16_t  d;                          /* diâmetro atual do corpo */
    char    ult_detalhe[40], ult_projeto[28];
} mascote_t;

static mascote_t g_m[FG_MAX_SESSOES];
static int g_qtd = 1;

/* Interrogações e rodapé global só existem no modo de sessão única: com a
 * tela dividida não há espaço, e detalhe demais em miniatura vira ruído. */
static lv_obj_t *g_interrog[QTD_INTERROG];

/* —— modo repouso —— */
static lv_obj_t *g_hora, *g_dia, *g_temp, *g_cond, *g_maxmin, *g_icone;
static bool g_em_repouso = false;
static char g_icone_atual[12] = "";

/* —— painel de limites (tile 1) —— */
#define MAX_BARRAS 4
static lv_obj_t *g_tile_painel;
static lv_obj_t *g_bar_rotulo[MAX_BARRAS], *g_bar_pct[MAX_BARRAS];
static lv_obj_t *g_bar[MAX_BARRAS], *g_bar_reset[MAX_BARRAS];
static lv_obj_t *g_frescor;

static uint32_t g_refrescos, g_ultima_medida;

/* ————————————————————————————————————————————————
 *  Ícones de tempo, desenhados por primitivas
 * ———————————————————————————————————————————————— */
#define C_SOL    lv_color_make(240, 176,  72)
#define C_LUA    lv_color_make(226, 232, 242)
#define C_NUVEM  lv_color_make(150, 160, 176)
#define C_CHUVA  lv_color_make(104, 162, 214)

/* lv_obj_create devolve o objeto CLICAVEL por padrao, e objeto clicavel
 * captura o arrasto antes que ele chegue ao tileview — que e quem rola para
 * o painel de limites. Como a tela e coberta por corpos, olhos e fagulhas,
 * bastava um deles clicavel para o deslize morrer. Tudo que e decoracao
 * passa por aqui. */
static void so_decoracao(lv_obj_t *o)
{
    lv_obj_remove_flag(o, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(o, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_flag(o, LV_OBJ_FLAG_EVENT_BUBBLE);   /* gesto sobe para o pai */
}

static lv_obj_t *disco(lv_obj_t *pai, int d, lv_color_t cor, int x, int y)
{
    lv_obj_t *o = lv_obj_create(pai);
    lv_obj_set_size(o, d, d);
    lv_obj_set_style_radius(o, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_border_width(o, 0, 0);
    lv_obj_set_style_bg_color(o, cor, 0);
    lv_obj_set_style_pad_all(o, 0, 0);
    so_decoracao(o);
    lv_obj_align(o, LV_ALIGN_CENTER, x, y);
    return o;
}

static lv_obj_t *barra(lv_obj_t *pai, int w, int h, lv_color_t cor, int x, int y)
{
    lv_obj_t *o = lv_obj_create(pai);
    lv_obj_set_size(o, w, h);
    lv_obj_set_style_radius(o, h < w ? h / 2 : w / 2, 0);
    lv_obj_set_style_border_width(o, 0, 0);
    lv_obj_set_style_bg_color(o, cor, 0);
    lv_obj_set_style_pad_all(o, 0, 0);
    so_decoracao(o);
    lv_obj_align(o, LV_ALIGN_CENTER, x, y);
    return o;
}

static void nuvem(lv_obj_t *p, int dx, int dy, lv_color_t c)
{
    disco(p, 34, c, dx - 16, dy);
    disco(p, 46, c, dx + 4,  dy - 8);
    disco(p, 30, c, dx + 24, dy + 2);
    barra(p, 74, 26, c, dx + 4, dy + 10);
}

static void montar_icone(const char *nome)
{
    lv_obj_clean(g_icone);
    if (!nome || !*nome) return;

    const bool tem_lua = strstr(nome, "moon") != NULL;
    const bool tem_sol = strstr(nome, "sun")  != NULL;

    if (!strcmp(nome, "sun") || !strcmp(nome, "moon")) {
        if (tem_sol) {
            disco(g_icone, 52, C_SOL, 0, 0);
            barra(g_icone, 10, 34, C_SOL,  0, -44);
            barra(g_icone, 10, 34, C_SOL,  0,  44);
            barra(g_icone, 34, 10, C_SOL, -44,  0);
            barra(g_icone, 34, 10, C_SOL,  44,  0);
            barra(g_icone, 10, 22, C_SOL, -31, -31);
            barra(g_icone, 10, 22, C_SOL,  31,  31);
            barra(g_icone, 22, 10, C_SOL,  31, -31);
            barra(g_icone, 22, 10, C_SOL, -31,  31);
        } else {
            /* Crescente: disco cheio + disco preto deslocado. Só funciona
             * porque é AMOLED — o preto tem o pixel desligado e vira recorte
             * de verdade, não uma mancha escura. */
            disco(g_icone, 62, C_LUA, 0, 0);
            disco(g_icone, 54, lv_color_black(), 18, -8);
        }
        return;
    }

    if (tem_sol || tem_lua) {
        if (tem_sol) {
            disco(g_icone, 38, C_SOL, 20, -22);
            barra(g_icone, 8, 20, C_SOL, 20, -50);
            barra(g_icone, 20, 8, C_SOL, 48, -22);
        } else {
            disco(g_icone, 40, C_LUA, 22, -22);
            disco(g_icone, 34, lv_color_black(), 34, -30);
        }
        nuvem(g_icone, -6, 14, C_NUVEM);
        return;
    }

    nuvem(g_icone, 0, !strcmp(nome, "cloud") ? 0 : -12, C_NUVEM);

    if (!strcmp(nome, "rain")) {
        for (int i = 0; i < 3; i++)
            barra(g_icone, 7, 22, C_CHUVA, -24 + i * 24, 34);
    } else if (!strcmp(nome, "snow")) {
        for (int i = 0; i < 3; i++)
            disco(g_icone, 12, C_LUA, -24 + i * 24, 34);
    } else if (!strcmp(nome, "storm")) {
        barra(g_icone, 12, 30, lv_color_make(240, 200, 80), -4, 30);
        barra(g_icone, 12, 22, lv_color_make(240, 200, 80),  8, 42);
    }
}

/* ————————————————————————————————————————————————
 *  Layout: quantos mascotes, de que tamanho, onde
 * ———————————————————————————————————————————————— */
typedef struct { int16_t d, x, y; const lv_font_t *f_det, *f_proj; } vaga_t;

/* Uma sessão ocupa a tela toda; a partir de duas, divide.
 * 3 e 4 usam a mesma grade 2x2 — com 3, a última vaga fica vazia, que é
 * melhor do que uma fileira de três achatados. */
static void vaga_de(int total, int i, vaga_t *v)
{
    if (total <= 1) {
        *v = (vaga_t){236, 0, -12, &lv_font_montserrat_32, &lv_font_montserrat_20};
    } else if (total == 2) {
        *v = (vaga_t){178, (i == 0 ? -118 : 118), -10,
                      &lv_font_montserrat_24, &lv_font_montserrat_16};
    } else {
        const int16_t px[4] = {-118, 118, -118, 118};
        const int16_t py[4] = {-118, -118, 108, 108};
        *v = (vaga_t){140, px[i], py[i],
                      &lv_font_montserrat_20, &lv_font_montserrat_16};
    }
}

static void aplicar_layout(int total)
{
    for (int i = 0; i < FG_MAX_SESSOES; i++) {
        mascote_t *m = &g_m[i];
        bool ativo = i < total;
        /* chama entra na lista: ela e IRMA do corpo, nao filha. Olhos e
         * boca somem junto com o corpo por serem filhos; a chama nao,
         * e ficaria pairando sozinha sobre o relogio. */
        lv_obj_t *objs[] = {m->corpo, m->fagulha, m->detalhe, m->projeto,
                            m->chama, m->foto, m->braco[0], m->braco[1]};
        for (size_t k = 0; k < 8; k++) {
            if (!objs[k]) continue;
            if (ativo) lv_obj_remove_flag(objs[k], LV_OBJ_FLAG_HIDDEN);
            else       lv_obj_add_flag(objs[k], LV_OBJ_FLAG_HIDDEN);
        }
        if (!ativo) continue;

        vaga_t v; vaga_de(total, i, &v);
        /* Com foto, o boneco desenhado inteiro sai de cena. Deixar os dois
         * visiveis nao daria um hibrido, daria olhos flutuando sobre a
         * imagem. */
        if (m->foto) {
            lv_obj_t *desenho[] = {m->corpo, m->fagulha, m->chama};
            for (size_t k = 0; k < 3; k++)
                lv_obj_add_flag(desenho[k], LV_OBJ_FLAG_HIDDEN);
            lv_obj_set_size(m->foto, v.d, v.d);
            lv_obj_align(m->foto, LV_ALIGN_CENTER, v.x, v.y);
        }
        m->d = v.d;
        /* Carcaca: quadrada com cantos generosos — o Macintosh original.
         * A tela ocupa 70% dela e fica deslocada para cima, deixando embaixo
         * a faixa onde ficaria o drive de disquete. */
        lv_obj_set_size(m->corpo, v.d, v.d);
        lv_obj_set_style_radius(m->corpo, v.d * 22 / 100, 0);
        lv_obj_align(m->corpo, LV_ALIGN_CENTER, v.x, v.y);

        int16_t td = v.d * 70 / 100, th = td * 82 / 100;
        int16_t ty = -v.d * 6 / 100, tr = td * 12 / 100;

        /* Moldura 4% maior que a tela e 2% mais baixa: a sobra aparece so em
         * cima, que e onde a sombra de um vao afundado cai. */
        lv_obj_set_size(m->moldura, td + v.d * 5 / 100, th + v.d * 5 / 100);
        lv_obj_set_style_radius(m->moldura, tr + v.d * 2 / 100, 0);
        lv_obj_align(m->moldura, LV_ALIGN_CENTER, 0, ty - v.d * 1 / 100);

        lv_obj_set_size(m->tela, td, th);
        lv_obj_set_style_radius(m->tela, tr, 0);
        lv_obj_align(m->tela, LV_ALIGN_CENTER, 0, ty);

        /* Luz: cobre o terco superior da tela e some para baixo. */
        lv_obj_set_size(m->luz, td, th * 62 / 100);
        lv_obj_set_style_radius(m->luz, tr, 0);
        lv_obj_align(m->luz, LV_ALIGN_TOP_MID, 0, 0);

        int16_t sh = v.d / 90; if (sh < 1) sh = 1;
        for (int i = 0; i < 2; i++) {
            lv_obj_set_size(m->scan[i], td, sh);
            lv_obj_align(m->scan[i], LV_ALIGN_CENTER, 0,
                         (i == 0 ? -1 : 1) * th * 26 / 100);
        }

        /* Faixa de luz no topo da carcaca, acompanhando o arredondamento. */
        lv_obj_set_size(m->topo, v.d * 72 / 100, v.d * 26 / 100);
        lv_obj_set_style_radius(m->topo, v.d * 13 / 100, 0);
        lv_obj_align(m->topo, LV_ALIGN_TOP_MID, 0, v.d * 4 / 100);

        /* Bracos: menores, mais baixos e da cor da SOMBRA da carcaca. Antes
         * eram claros e do tamanho de asas — pareciam algodao colado. */
        int16_t bl = v.d * 10 / 100, bh = v.d * 20 / 100;
        for (int b = 0; b < 2; b++) {
            lv_obj_set_size(m->braco[b], bl, bh);
            lv_obj_set_style_radius(m->braco[b], bl / 2, 0);
            lv_obj_align(m->braco[b], LV_ALIGN_CENTER,
                         v.x + (b == 0 ? -1 : 1) * (v.d / 2 + bl / 4),
                         v.y + v.d * 22 / 100);
        }

        lv_obj_set_style_text_font(m->detalhe, v.f_det, 0);
        lv_obj_set_style_text_font(m->projeto, v.f_proj, 0);
        lv_obj_align(m->detalhe, LV_ALIGN_CENTER, v.x, v.y + v.d / 2 + 26);
        lv_obj_align(m->projeto, LV_ALIGN_CENTER, v.x, v.y + v.d / 2 + 54);

        m->p_alt = -1;   /* força reposicionar os olhos na nova escala */
    }
    /* Interrogações e órbita larga só cabem com um mascote só. */
    for (int k = 0; k < QTD_INTERROG; k++)
        lv_obj_add_flag(g_interrog[k], LV_OBJ_FLAG_HIDDEN);
}

fg_estado_t ui_estado_de_texto(const char *s)
{
    if (!s) return FG_OCIOSO;
    if (!strcmp(s, "working")) return FG_TRABALHANDO;
    if (!strcmp(s, "tool"))    return FG_FERRAMENTA;
    if (!strcmp(s, "asking"))  return FG_PERGUNTANDO;
    if (!strcmp(s, "waiting")) return FG_ESPERANDO;
    if (!strcmp(s, "done"))    return FG_CONCLUIDO;
    if (!strcmp(s, "error"))   return FG_ERRO;
    return FG_OCIOSO;
}

static inline int16_t aproximar(int16_t atual, int16_t alvo, int passo)
{
    int16_t d = alvo - atual;
    if (d == 0) return atual;
    int16_t inc = d / passo;
    return inc ? atual + inc : alvo;
}

static void ao_refrescar(lv_event_t *e) { (void) e; g_refrescos++; }

/* ————————————————————————————————————————————————
 *  Animação
 * ———————————————————————————————————————————————— */
static void animar_um(mascote_t *m, uint32_t agora, bool sozinho)
{
    const alvo_t *A = &ALVO[m->alvo];

    /* Com foto, o quadro a quadro nao existe.
     *
     * A respiracao a 60fps foi feita para um boneco DESENHADO: era ela que
     * dava vida a formas geometricas. Uma imagem ja e o personagem inteiro, e
     * so precisa mudar quando o estado muda.
     *
     * Manter o laco rodando custava caro: cada quadro reinvalidava uma imagem
     * de 236x236 com alfa, que atravessa o buffer de 8 linhas em 30 tiras.
     * Medido: 6 FPS e 1,6KB de RAM interna no minimo. Parando o laco, a tela
     * simplesmente fica quieta ate ter noticia nova — que e o comportamento
     * certo para um indicador de status. */
    if (m->foto) {
        if (m->p_boca != m->alvo || m->p_esc != (int16_t) m->d) {
            m->p_boca = m->alvo;
            m->p_esc  = m->d;
            lv_image_set_src(m->foto, &s_dsc[m->alvo]);
        }
        return;
    }
    const cor_t *C = &COR[m->alvo];
    /* Escala das medidas do olho em relação ao mascote cheio (236px). */
    const int esc = m->d;

    /* Cor: troca direta. Interpolar repintava o corpo a cada passo, e cada
     * repintura varre a tela em faixas — 20 varreduras por transição viravam
     * listras visíveis. Uma varredura por mudança é o mínimo possível. */
    if (m->alvo != m->anterior) {
        m->anterior = m->alvo;
        /* A cor do estado e a LUZ da tela, nao a tinta do boneco. */
        lv_obj_set_style_bg_color(m->tela, lv_color_make(C->r, C->g, C->b), 0);
        lv_obj_set_style_bg_grad_color(m->tela, lv_color_make(C->dr, C->dg, C->db), 0);
    }

    /* Respiração vai nos OLHOS, não no corpo: qualquer mudança no corpo
     * invalida a área toda e o painel a entrega em faixas sequenciais,
     * desenhando costuras. Os olhos são pequenos e não têm esse custo. */
    float fase = (agora % 2600) / 2600.0f * 2.0f * (float) M_PI;
    int16_t respiro = (int16_t)(sinf(fase) * (A->respira / 2 + 1)) * esc / 236;

    /* Piscada por fase decorrida: fecha e abre simetricamente. */
    if (agora > m->prox_piscada) {
        m->inicio_piscada = agora;
        m->prox_piscada = agora + 3000 + (agora % 4000);
    }
    int16_t fechamento = 256;
    uint32_t dec = agora - m->inicio_piscada;
    if (m->inicio_piscada && dec < PISCADA_MS) {
        const uint32_t meio = PISCADA_MS / 2;
        fechamento = dec < meio ? 256 - (int16_t)(dec * 256 / meio)
                                : (int16_t)((dec - meio) * 256 / meio);
    }

    m->olho_alt = aproximar(m->olho_alt, A->olho_alt, 6);
    m->olho_dx  = aproximar(m->olho_dx,  A->olho_dx,  6);
    m->olho_dy  = aproximar(m->olho_dy,  A->olho_dy,  6);

    int16_t alt = m->olho_alt * fechamento / 256 * esc / 236;
    int16_t larg = 25 * esc / 236;
    if (alt < 2) alt = 2;
    if (larg < 6) larg = 6;
    int16_t dx = m->olho_dx * esc / 236, dy = (m->olho_dy + respiro) * esc / 236;

    if (alt != m->p_alt || dx != m->p_dx || dy != m->p_dy) {
        m->p_alt = alt; m->p_dx = dx; m->p_dy = dy;

        /* SO o branco do olho muda por quadro.
         *
         * Esta guarda dispara quase todo quadro, porque `alt` acompanha a
         * respiracao. Na primeira versao do rosto eu coloquei pupila,
         * sobrancelha e chama aqui dentro — e as sobras voltaram na hora.
         * Objeto girado reposicionado 60 vezes por segundo, em modo parcial
         * com buffer de 16 linhas, deixa rastro: a invalidacao da posicao
         * antiga nao cobre o que a rotacao desenhou fora da caixa.
         *
         * O comentario no topo deste arquivo ja dizia isso, e eu passei por
         * cima dele. Fica registrado. */
        int16_t sep = 30 * esc / 236;
        for (int i = 0; i < 2; i++) {
            lv_obj_set_size(m->olho[i], larg, alt);
            lv_obj_align(m->olho[i], LV_ALIGN_CENTER,
                         (i == 0 ? -sep : sep) + dx, dy);
            /* A pupila some quando o olho fecha, senao vaza pela palpebra. */
            lv_obj_set_style_opa(m->pupila[i],
                                 alt > larg / 3 ? LV_OPA_COVER : LV_OPA_TRANSP, 0);
        }
    }

    /* —— rosto: so muda quando o ESTADO ou a ESCALA mudam ——
     * Nada aqui precisa acompanhar a respiracao. Sobrancelha e boca sao
     * expressao, e expressao muda quando o Claude muda de estado, nao 60
     * vezes por segundo. */
    if (m->p_boca != m->alvo || m->p_esc != esc) {
        m->p_boca = m->alvo;
        m->p_esc  = esc;


        int16_t sep = 42 * esc / 236;
        int16_t lg  = 25 * esc / 236;
        int16_t rp  = lg * 52 / 100, rb = lg * 20 / 100;
        if (rp < 3) rp = 3;
        if (rb < 2) rb = 2;

        for (int i = 0; i < 2; i++) {
            int16_t ox = A->olhar_x * (lg / 3) / 100;
            int16_t oy = A->olhar_y * (lg / 3) / 100;
            lv_obj_set_size(m->pupila[i], rp, rp);
            lv_obj_align(m->pupila[i], LV_ALIGN_CENTER, ox, oy);
            lv_obj_set_size(m->brilho[i], rb, rb);
            lv_obj_align(m->brilho[i], LV_ALIGN_CENTER, -rp / 4, -rp / 4);

            /* A inclinacao vira diferenca de altura entre as duas pontas.
             * `externa` espelha o lado esquerdo; com sob_invertida quem sobe
             * e a ponta INTERNA — e e so isso que separa bravo de
             * preocupado. */
            int16_t sl = 46 * esc / 236, sh = 8 * esc / 236;
            if (sh < 2) sh = 2;
            int externa = (i == 0) ? -1 : 1;
            int giro = (A->sob_invertida ? -externa : externa) * A->sob_ang;
            int16_t queda = (int16_t)(sl * giro / 90);   /* aprox. de tan */
            m->sob_pts[i][0].x = 0;
            m->sob_pts[i][0].y = sh + queda / 2;
            m->sob_pts[i][1].x = sl;
            m->sob_pts[i][1].y = sh - queda / 2;
            lv_obj_set_style_line_width(m->sobrancelha[i], sh, 0);
            lv_line_set_points(m->sobrancelha[i], m->sob_pts[i], 2);
            lv_obj_align(m->sobrancelha[i], LV_ALIGN_CENTER,
                         (i == 0 ? -sep : sep),
                         -(A->olho_alt / 2) - (18 - A->sob_dy) * esc / 236);
        }

        int16_t bd, bw, a1, a2;

    /* —— boca ——
     * Um arco so, reposicionado. Angulos do LVGL: 0 grau aponta para as 3
     * horas e cresce no sentido horario, entao 90 e embaixo. Arco embaixo
     * curva para cima e vira sorriso; arco em cima vira aflicao. */
        switch (A->boca) {
            case BOCA_SORRISAO: bd = 74; bw = 9; a1 = 35;  a2 = 145; break;
            case BOCA_SORRISO:  bd = 62; bw = 7; a1 = 55;  a2 = 125; break;
            case BOCA_PEQUENA:  bd = 44; bw = 6; a1 = 68;  a2 = 112; break;
            case BOCA_O:        bd = 26; bw = 9; a1 = 0;   a2 = 359; break;
            case BOCA_ONDA:     bd = 58; bw = 7; a1 = 235; a2 = 305; break;
            default:            bd = 96; bw = 6; a1 = 82;  a2 = 98;  break;
        }
        int16_t dbd = bd * esc / 236, dbw = bw * esc / 236;
        if (dbw < 2) dbw = 2;
        lv_obj_set_size(m->boca, dbd, dbd);
        lv_obj_set_style_arc_width(m->boca, dbw, LV_PART_MAIN);
        lv_arc_set_bg_angles(m->boca, a1, a2);
        /* A onda e um arco de cima: sobe o objeto para a curva cair onde a
         * boca deve estar, em vez de ficar no meio do rosto. */
        int16_t by = (A->boca == BOCA_ONDA ? 58 : 30) * esc / 236;
        lv_obj_align(m->boca, LV_ALIGN_CENTER, 0, by);
    }

    /* Fagulha do topo: paira acima da cabeca e tremula. Morre no offline —
     * sem o outro lado, nao ha o que arder. */
    if (m->alvo == FG_SEM_REDE) {
        lv_obj_add_flag(m->chama, LV_OBJ_FLAG_HIDDEN);
    } else {
        /* Parada de proposito. Tremular era mover um objeto sobre o fundo a
         * cada quadro — mais uma fonte de rastro, pelo mesmo motivo das
         * sobrancelhas. Quem se mexe aqui e a fagulha em orbita, que ja da
         * o sinal de movimento. */
        int16_t cd = 16 * esc / 236;
        if (cd < 4) cd = 4;
        vaga_t vc; vaga_de(g_qtd, (int)(m - g_m), &vc);
        lv_obj_remove_flag(m->chama, LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_size(m->chama, cd, cd * 3 / 2);
        lv_obj_set_style_radius(m->chama, cd / 2, 0);
        lv_obj_align(m->chama, LV_ALIGN_CENTER, vc.x, vc.y - esc / 2 - cd);
    }

    /* Fagulha: ângulo ACUMULADO e velocidade interpolada. Derivar de
     * (tempo % periodo) fazia a bolinha teleportar ao mudar de estado. */
    float vel_alvo = A->orbita / 255.0f * 5.0f;
    m->vel += (vel_alvo - m->vel) * 0.05f;
    m->ang += m->vel * (PERIODO_MS / 1000.0f);
    if (m->ang > 2.0f * (float) M_PI) m->ang -= 2.0f * (float) M_PI;

    if (A->orbita) {
        lv_obj_remove_flag(m->fagulha, LV_OBJ_FLAG_HIDDEN);
        int rx = (esc * 152) / 236, ry = (esc * 94) / 236;
        vaga_t v; vaga_de(g_qtd, (int)(m - g_m), &v);
        lv_obj_align(m->fagulha, LV_ALIGN_CENTER,
                     v.x + (int16_t)(cosf(m->ang) * rx),
                     v.y + (int16_t)(sinf(m->ang) * ry));
        lv_obj_set_style_bg_color(m->fagulha, lv_color_make(C->r, C->g, C->b), 0);
    } else {
        lv_obj_add_flag(m->fagulha, LV_OBJ_FLAG_HIDDEN);
    }

    /* Interrogações subindo: só no modo de sessão única. */
    if (sozinho && A->interrog) {
        for (int i = 0; i < QTD_INTERROG; i++) {
            lv_obj_remove_flag(g_interrog[i], LV_OBJ_FLAG_HIDDEN);
            uint32_t ciclo = (agora + i * 1000) % 3000;
            float sobe = ciclo / 3000.0f;
            lv_obj_align(g_interrog[i], LV_ALIGN_CENTER,
                         (int16_t)(sinf(sobe * 3.4f + i * 2.2f) * 24) + (i - 1) * 13,
                         -132 - (int16_t)(sobe * 96));
            lv_obj_set_style_opa(g_interrog[i],
                                 (lv_opa_t)(sinf(sobe * (float) M_PI) * 255), 0);
            lv_obj_set_style_text_color(g_interrog[i],
                                        lv_color_make(C->r, C->g, C->b), 0);
        }
    } else if (sozinho) {
        for (int i = 0; i < QTD_INTERROG; i++)
            lv_obj_add_flag(g_interrog[i], LV_OBJ_FLAG_HIDDEN);
    }
}

static void animar(lv_timer_t *t)
{
    (void) t;
    if (g_em_repouso) return;   /* mascotes escondidos: animar é desperdício */

    const uint32_t agora = lv_tick_get();
    for (int i = 0; i < g_qtd && i < FG_MAX_SESSOES; i++)
        animar_um(&g_m[i], agora, g_qtd == 1);

    if (agora - g_ultima_medida >= 5000) {
        ESP_LOGI(TAG, "FPS: %lu  (%d sessao/oes)",
                 (unsigned long)(g_refrescos * 1000 / (agora - g_ultima_medida)), g_qtd);
        g_refrescos = 0;
        g_ultima_medida = agora;
    }
}

/* ————————————————————————————————————————————————
 *  Construção
 * ———————————————————————————————————————————————— */
static void criar_painel(lv_obj_t *pai)
{
    lv_obj_t *titulo = lv_label_create(pai);
    lv_label_set_text(titulo, "USAGE LIMITS");
    lv_obj_set_style_text_font(titulo, &lv_font_montserrat_20, 0);
    lv_obj_set_style_text_color(titulo, lv_color_make(120, 128, 140), 0);
    lv_obj_align(titulo, LV_ALIGN_TOP_LEFT, 34, 44);

    for (int i = 0; i < MAX_BARRAS; i++) {
        const int y = 90 + i * 78;

        g_bar_rotulo[i] = lv_label_create(pai);
        lv_obj_set_style_text_font(g_bar_rotulo[i], &lv_font_montserrat_24, 0);
        lv_obj_set_style_text_color(g_bar_rotulo[i], lv_color_make(200, 206, 214), 0);
        lv_obj_align(g_bar_rotulo[i], LV_ALIGN_TOP_LEFT, 34, y);
        lv_label_set_text(g_bar_rotulo[i], "");

        g_bar_pct[i] = lv_label_create(pai);
        lv_obj_set_style_text_font(g_bar_pct[i], &lv_font_montserrat_38, 0);
        lv_obj_align(g_bar_pct[i], LV_ALIGN_TOP_RIGHT, -34, y - 2);
        lv_label_set_text(g_bar_pct[i], "");

        g_bar[i] = lv_bar_create(pai);
        lv_obj_set_size(g_bar[i], 412, 8);
        lv_obj_align(g_bar[i], LV_ALIGN_TOP_LEFT, 34, y + 26);
        lv_bar_set_range(g_bar[i], 0, 100);
        lv_obj_set_style_bg_color(g_bar[i], lv_color_make(38, 44, 54), 0);
        lv_obj_set_style_radius(g_bar[i], 4, 0);
        lv_obj_set_style_radius(g_bar[i], 4, LV_PART_INDICATOR);
        so_decoracao(g_bar[i]);

        g_bar_reset[i] = lv_label_create(pai);
        lv_obj_set_style_text_font(g_bar_reset[i], &lv_font_montserrat_20, 0);
        lv_obj_set_style_text_color(g_bar_reset[i], lv_color_make(120, 128, 140), 0);
        lv_obj_align(g_bar_reset[i], LV_ALIGN_TOP_LEFT, 34, y + 40);
        lv_label_set_text(g_bar_reset[i], "");
    }

    g_frescor = lv_label_create(pai);
    lv_obj_set_style_text_font(g_frescor, &lv_font_montserrat_20, 0);
    lv_obj_set_style_text_color(g_frescor, lv_color_make(120, 128, 140), 0);
    lv_obj_align(g_frescor, LV_ALIGN_BOTTOM_MID, 0, -40);
    lv_label_set_text(g_frescor, "");
}

static void criar_mascote(lv_obj_t *pai, mascote_t *m)
{
    /* CARCACA: a caixa creme do computador. */
    m->corpo = lv_obj_create(pai);
    lv_obj_set_style_border_width(m->corpo, 0, 0);
    lv_obj_set_style_pad_all(m->corpo, 0, 0);
    lv_obj_set_style_bg_color(m->corpo, C_CARCACA_T, 0);
    lv_obj_set_style_bg_grad_color(m->corpo, C_CARCACA_B, 0);
    lv_obj_set_style_bg_grad_dir(m->corpo, LV_GRAD_DIR_VER, 0);
    so_decoracao(m->corpo);

    /* BRACOS: dois toquinhos nas laterais. Filhos da carcaca, entao somem
     * junto com ela sem precisar entrar em lista nenhuma. */
    for (int i = 0; i < 2; i++) {
        m->braco[i] = lv_obj_create(pai);
        lv_obj_set_style_border_width(m->braco[i], 0, 0);
        lv_obj_set_style_bg_color(m->braco[i], C_CARCACA_B, 0);
        lv_obj_set_style_pad_all(m->braco[i], 0, 0);
        so_decoracao(m->braco[i]);
    }

    /* MOLDURA: um retangulo escuro logo atras da tela, deslocado para baixo.
     * E o truque mais barato de profundidade que existe — o olho le a sombra
     * na borda de cima como "isto esta AFUNDADO na carcaca". Sem ela, tela e
     * carcaca parecem adesivos no mesmo plano. */
    m->moldura = lv_obj_create(m->corpo);
    lv_obj_set_style_border_width(m->moldura, 0, 0);
    lv_obj_set_style_bg_color(m->moldura, lv_color_make(150, 138, 118), 0);
    lv_obj_set_style_pad_all(m->moldura, 0, 0);
    so_decoracao(m->moldura);

    /* BRILHO DO TOPO: faixa clara na parte de cima da carcaca. Plastico
     * arredondado sob luz de cima tem essa banda; sem ela a caixa e um
     * retangulo pintado. */
    m->topo = lv_obj_create(m->corpo);
    lv_obj_set_style_border_width(m->topo, 0, 0);
    lv_obj_set_style_bg_color(m->topo, lv_color_white(), 0);
    lv_obj_set_style_bg_opa(m->topo, LV_OPA_30, 0);
    lv_obj_set_style_bg_grad_color(m->topo, lv_color_white(), 0);
    lv_obj_set_style_bg_grad_dir(m->topo, LV_GRAD_DIR_VER, 0);
    lv_obj_set_style_bg_main_opa(m->topo, LV_OPA_40, 0);
    lv_obj_set_style_bg_grad_opa(m->topo, LV_OPA_TRANSP, 0);
    lv_obj_set_style_pad_all(m->topo, 0, 0);
    so_decoracao(m->topo);

    /* TELA: o rosto. E ela que recebe a cor do estado. */
    m->tela = lv_obj_create(m->corpo);
    lv_obj_set_style_border_width(m->tela, 0, 0);
    lv_obj_set_style_pad_all(m->tela, 0, 0);
    lv_obj_set_style_bg_grad_dir(m->tela, LV_GRAD_DIR_VER, 0);
    so_decoracao(m->tela);

    /* LUZ: nucleo claro no meio da tela, esmaecendo para baixo. Um CRT nao
     * ilumina por igual — o centro estoura e as bordas caem. E o que mais
     * faz a tela parecer ACESA em vez de pintada. */
    m->luz = lv_obj_create(m->tela);
    lv_obj_set_style_border_width(m->luz, 0, 0);
    lv_obj_set_style_bg_color(m->luz, lv_color_white(), 0);
    lv_obj_set_style_bg_grad_color(m->luz, lv_color_white(), 0);
    lv_obj_set_style_bg_grad_dir(m->luz, LV_GRAD_DIR_VER, 0);
    lv_obj_set_style_bg_main_opa(m->luz, LV_OPA_40, 0);
    lv_obj_set_style_bg_grad_opa(m->luz, LV_OPA_TRANSP, 0);
    lv_obj_set_style_pad_all(m->luz, 0, 0);
    so_decoracao(m->luz);

    /* SCANLINES: duas faixas escuras finas. Sao elas que dizem "isto e uma
     * tela de varredura", nao um retangulo laranja. */
    for (int i = 0; i < 2; i++) {
        m->scan[i] = lv_obj_create(m->tela);
        lv_obj_set_style_border_width(m->scan[i], 0, 0);
        lv_obj_set_style_radius(m->scan[i], 0, 0);
        lv_obj_set_style_bg_color(m->scan[i], lv_color_black(), 0);
        lv_obj_set_style_bg_opa(m->scan[i], LV_OPA_10, 0);
        lv_obj_set_style_pad_all(m->scan[i], 0, 0);
        so_decoracao(m->scan[i]);
    }

    for (int i = 0; i < 2; i++) {
        /* BRANCO do olho. Antes o olho inteiro era escuro — duas frestas num
         * corpo redondo, que lia como focinho. Olho de verdade tem branco,
         * pupila e um ponto de brilho; sem o brilho ele vira buraco. */
        m->olho[i] = lv_obj_create(m->tela);
        /* Olho de PIXEL: quadrado com canto minimo. Numa tela CRT o
         * rosto e desenhado por blocos, nao por formas organicas. */
        lv_obj_set_style_radius(m->olho[i], 2, 0);
        lv_obj_set_style_border_width(m->olho[i], 0, 0);
        lv_obj_set_style_bg_color(m->olho[i], lv_color_make(74, 44, 18), 0);
        lv_obj_set_style_pad_all(m->olho[i], 0, 0);
        so_decoracao(m->olho[i]);

        m->pupila[i] = lv_obj_create(m->olho[i]);
        lv_obj_set_style_radius(m->pupila[i], LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_border_width(m->pupila[i], 0, 0);
        lv_obj_set_style_bg_color(m->pupila[i], lv_color_make(26, 18, 24), 0);
        lv_obj_set_style_pad_all(m->pupila[i], 0, 0);
        so_decoracao(m->pupila[i]);

        m->brilho[i] = lv_obj_create(m->pupila[i]);
        lv_obj_set_style_radius(m->brilho[i], LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_border_width(m->brilho[i], 0, 0);
        lv_obj_set_style_bg_color(m->brilho[i], lv_color_white(), 0);
        lv_obj_set_style_pad_all(m->brilho[i], 0, 0);
        so_decoracao(m->brilho[i]);

        /* Sobrancelha como LINHA, nao como retangulo girado.
         *
         * A primeira versao usava transform_rotation, e isso custou caro: no
         * LVGL 9 qualquer objeto transformado e renderizado num buffer de
         * CAMADA temporario. Oito sobrancelhas = oito camadas disputando a
         * RAM interna, que aqui e o recurso mais escasso da placa. O
         * resultado foi `Failed to allocate priv TX buffer` e o desenho
         * falhando de vez — que na tela aparece como coisa sobre coisa,
         * porque o pixel velho nunca e coberto.
         *
         * Uma linha de dois pontos ja nasce inclinada. Zero camada. */
        m->sobrancelha[i] = lv_line_create(m->tela);
        lv_obj_set_style_line_color(m->sobrancelha[i], lv_color_make(40, 24, 22), 0);
        lv_obj_set_style_line_opa(m->sobrancelha[i], LV_OPA_80, 0);
        lv_obj_set_style_line_rounded(m->sobrancelha[i], true, 0);
        so_decoracao(m->sobrancelha[i]);
    }

    /* Boca: UM arco serve para todas as formas. Voltado para baixo vira
     * sorriso, para cima vira aflicao, fechado em 360 vira o "o" de surpresa.
     * Sete widgets diferentes dariam o mesmo resultado com sete vezes mais
     * objetos na tela — e objeto custa varredura. */
    m->boca = lv_arc_create(m->tela);
    lv_obj_remove_style(m->boca, NULL, LV_PART_KNOB);
    lv_obj_set_style_arc_width(m->boca, 0, LV_PART_INDICATOR);
    lv_obj_set_style_arc_color(m->boca, lv_color_make(40, 24, 22), LV_PART_MAIN);
    lv_obj_set_style_arc_opa(m->boca, LV_OPA_80, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(m->boca, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(m->boca, 0, 0);
    so_decoracao(m->boca);
    m->p_boca = -1;

    /* Mascote de imagem. Fica ACIMA de tudo e, quando existe, o desenho
     * inteiro e escondido — nao ha meio-termo entre os dois. */
    if (s_tem_fotos) {
        m->foto = lv_image_create(pai);
        so_decoracao(m->foto);
    }

    /* A fagulha que paira acima da cabeca — o que amarra o boneco ao nome. */
    m->chama = lv_obj_create(pai);
    lv_obj_set_style_radius(m->chama, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_border_width(m->chama, 0, 0);
    lv_obj_set_style_bg_color(m->chama, lv_color_make(255, 214, 130), 0);
    lv_obj_set_style_bg_grad_color(m->chama, lv_color_make(250, 140, 50), 0);
    lv_obj_set_style_bg_grad_dir(m->chama, LV_GRAD_DIR_VER, 0);
    lv_obj_set_style_pad_all(m->chama, 0, 0);
    so_decoracao(m->chama);

    m->fagulha = lv_obj_create(pai);
    lv_obj_set_size(m->fagulha, 14, 14);
    lv_obj_set_style_radius(m->fagulha, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_border_width(m->fagulha, 0, 0);
    lv_obj_add_flag(m->fagulha, LV_OBJ_FLAG_HIDDEN);
    so_decoracao(m->fagulha);

    m->detalhe = lv_label_create(pai);
    lv_obj_set_style_text_color(m->detalhe, lv_color_make(230, 233, 238), 0);
    lv_label_set_text(m->detalhe, "");

    m->projeto = lv_label_create(pai);
    lv_obj_set_style_text_color(m->projeto, lv_color_make(134, 144, 158), 0);
    lv_label_set_text(m->projeto, "");

    m->alvo = FG_SEM_REDE;
    m->anterior = FG_QTD;
    m->olho_alt = 6;
    m->p_alt = -1;
    m->ang = -(float) M_PI / 2;
    m->d = 236;
}

void ui_criar(void)
{
    lv_obj_t *raiz = lv_screen_active();
    lv_obj_set_style_bg_color(raiz, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(raiz, LV_OPA_COVER, 0);
    lv_obj_remove_flag(raiz, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *tv = lv_tileview_create(raiz);
    lv_obj_set_size(tv, 480, 480);
    lv_obj_set_style_bg_color(tv, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(tv, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(tv, 0, 0);
    lv_obj_set_scrollbar_mode(tv, LV_SCROLLBAR_MODE_OFF);

    lv_obj_t *tela = lv_tileview_add_tile(tv, 0, 0, LV_DIR_RIGHT);
    g_tile_painel  = lv_tileview_add_tile(tv, 1, 0, LV_DIR_LEFT);
    lv_obj_t *tiles[2] = {tela, g_tile_painel};
    for (int i = 0; i < 2; i++) {
        lv_obj_set_style_bg_color(tiles[i], lv_color_black(), 0);
        lv_obj_set_style_bg_opa(tiles[i], LV_OPA_COVER, 0);
        lv_obj_remove_flag(tiles[i], LV_OBJ_FLAG_SCROLLABLE);
    }
    criar_painel(g_tile_painel);

    /* carregar_fotos();  <- desenhado supera imagem aqui; ver commit */
    for (int i = 0; i < FG_MAX_SESSOES; i++) criar_mascote(tela, &g_m[i]);

    for (int i = 0; i < QTD_INTERROG; i++) {
        g_interrog[i] = lv_label_create(tela);
        lv_label_set_text(g_interrog[i], "?");
        lv_obj_set_style_text_font(g_interrog[i], &lv_font_montserrat_38, 0);
        lv_obj_add_flag(g_interrog[i], LV_OBJ_FLAG_HIDDEN);
    }

    /* —— repouso —— */
    g_hora = lv_label_create(tela);
    lv_obj_set_style_text_font(g_hora, &lv_font_montserrat_48, 0);
    lv_obj_set_style_text_color(g_hora, lv_color_make(238, 242, 248), 0);
    lv_label_set_text(g_hora, "--:--");
    lv_obj_align(g_hora, LV_ALIGN_CENTER, 0, -156);

    g_dia = lv_label_create(tela);
    lv_obj_set_style_text_font(g_dia, &lv_font_montserrat_28, 0);
    lv_obj_set_style_text_color(g_dia, lv_color_make(140, 150, 164), 0);
    lv_label_set_text(g_dia, "");
    lv_obj_align(g_dia, LV_ALIGN_CENTER, 0, -108);

    g_icone = lv_obj_create(tela);
    lv_obj_set_size(g_icone, 150, 150);
    lv_obj_set_style_bg_opa(g_icone, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(g_icone, 0, 0);
    lv_obj_set_style_pad_all(g_icone, 0, 0);
    so_decoracao(g_icone);
    lv_obj_align(g_icone, LV_ALIGN_CENTER, 0, -6);

    g_temp = lv_label_create(tela);
    lv_obj_set_style_text_font(g_temp, &lv_font_montserrat_48, 0);
    lv_obj_set_style_text_color(g_temp, lv_color_make(232, 132, 90), 0);
    lv_label_set_text(g_temp, "");
    /* 48 é a MAIOR Montserrat embutida no LVGL. Para passar disso sem gerar
     * fonte customizada, escalamos o rótulo. Aqui o transform é barato: a
     * temperatura muda a cada 15 min, não a cada quadro. */
    lv_obj_set_style_transform_pivot_x(g_temp, lv_pct(50), 0);
    lv_obj_set_style_transform_pivot_y(g_temp, lv_pct(50), 0);
    lv_obj_set_style_transform_scale_x(g_temp, 333, 0);   /* 256 = 100% */
    lv_obj_set_style_transform_scale_y(g_temp, 333, 0);
    lv_obj_align(g_temp, LV_ALIGN_CENTER, 0, 100);

    g_cond = lv_label_create(tela);
    lv_obj_set_style_text_font(g_cond, &lv_font_montserrat_28, 0);
    lv_obj_set_style_text_color(g_cond, lv_color_make(184, 192, 204), 0);
    lv_label_set_text(g_cond, "");
    lv_obj_align(g_cond, LV_ALIGN_CENTER, 0, 148);

    g_maxmin = lv_label_create(tela);
    lv_obj_set_style_text_font(g_maxmin, &lv_font_montserrat_24, 0);
    lv_obj_set_style_text_color(g_maxmin, lv_color_make(122, 130, 142), 0);
    lv_label_set_text(g_maxmin, "");
    lv_obj_align(g_maxmin, LV_ALIGN_CENTER, 0, 188);

    lv_obj_t *r[] = {g_hora, g_dia, g_icone, g_temp, g_cond, g_maxmin};
    for (size_t i = 0; i < sizeof(r) / sizeof(r[0]); i++)
        lv_obj_add_flag(r[i], LV_OBJ_FLAG_HIDDEN);

    aplicar_layout(1);
    g_ultima_medida = lv_tick_get();
    lv_display_add_event_cb(lv_display_get_default(), ao_refrescar,
                            LV_EVENT_REFR_READY, NULL);
    lv_timer_create(animar, PERIODO_MS, NULL);
}

/* ————————————————————————————————————————————————
 *  Atualização
 * ———————————————————————————————————————————————— */
void ui_atualizar(const fg_dados_t *d)
{
    if (!d) return;
    int n = d->qtd_sessoes;
    if (n > FG_MAX_SESSOES) n = FG_MAX_SESSOES;

    /* Nenhuma sessão ATIVA = relógio, imediatamente.
     *
     * O bridge já filtra: sessão que parou de iterar sai da lista. Amarrar o
     * repouso a isso (em vez de a um limiar próprio) evita o intervalo de
     * tela vazia que existiria entre o mascote sumir e o relógio entrar. */
    bool sem_sessao = (n == 0);
    bool repouso = sem_sessao && d->hora[0];
    if (sem_sessao) n = 1;   /* daqui para baixo, n é só o layout */

    bsp_display_lock(-1);

    /* Toda troca de arranjo repinta a tela inteira.
     *
     * POR QUE, em uma linha: esconder objeto no LVGL não apaga pixel — apenas
     * marca a área como suja para que ALGUÉM redesenhe por cima. Rodamos em
     * modo PARCIAL (buffer de 16 linhas, imposto pela disputa de RAM com o
     * WiFi), e nesse modo uma invalidação perdida não tem segunda chance: o
     * quadro seguinte só toca nas áreas sujas. O pixel antigo fica.
     *
     * Num LCD isso apareceria como borrão; num AMOLED os pixels são luz
     * própria e a sobra fica nítida, indistinguível de conteúdo válido. Foi o
     * que se viu: relógio, painel e mascote empilhados na mesma tela, todos
     * legíveis, todos restos de arranjos anteriores.
     *
     * O custo é um quadro cheio por TROCA — não por quadro. Trocar de modo
     * acontece na casa de segundos; redesenhar 480x480 uma vez é irrelevante
     * perto de conviver com lixo permanente na tela. */
    bool trocou_modo   = (repouso != g_em_repouso);
    bool trocou_layout = (!repouso && n != g_qtd);
    if (trocou_modo || trocou_layout) {
        lv_obj_invalidate(lv_screen_active());
    }

    if (repouso != g_em_repouso) {
        g_em_repouso = repouso;
        lv_obj_t *r[] = {g_hora, g_dia, g_icone, g_temp, g_cond, g_maxmin};
        for (size_t i = 0; i < sizeof(r) / sizeof(r[0]); i++) {
            if (repouso) lv_obj_remove_flag(r[i], LV_OBJ_FLAG_HIDDEN);
            else         lv_obj_add_flag(r[i], LV_OBJ_FLAG_HIDDEN);
        }
        if (repouso) {
            for (int i = 0; i < FG_MAX_SESSOES; i++) {
                /* A foto entra aqui pelo mesmo motivo que a chama entrou:
                 * e IRMA do corpo, nao filha, entao nao some por heranca.
                 * Sem isto ela fica pairando sobre o relogio — armadilha que
                 * ja pegou o rodape e a chama antes dela. */
                lv_obj_t *o[] = {g_m[i].corpo, g_m[i].fagulha, g_m[i].detalhe,
                                 g_m[i].projeto, g_m[i].chama, g_m[i].foto,
                                 g_m[i].braco[0], g_m[i].braco[1]};
                for (size_t k = 0; k < 8; k++)
                    if (o[k]) lv_obj_add_flag(o[k], LV_OBJ_FLAG_HIDDEN);
            }
            for (int k = 0; k < QTD_INTERROG; k++)
                lv_obj_add_flag(g_interrog[k], LV_OBJ_FLAG_HIDDEN);
        } else {
            g_qtd = -1;   /* força reaplicar o layout ao voltar */
        }
    }

    if (!repouso) {
        if (n != g_qtd) {
            g_qtd = n;
            aplicar_layout(n);
        }
        /* Sem sessão e sem relógio (o bridge caiu antes de mandar a hora):
         * mostramos um mascote ocioso EXPLÍCITO. Ler d->sessoes[0] aqui
         * pegaria lixo — quem chama passa um global que guarda a última
         * sessão vista, e a tela exibiria um fantasma de algo já encerrado. */
        static const fg_sessao_t VAZIA = {.estado = FG_OCIOSO};
        for (int i = 0; i < n; i++) {
            const fg_sessao_t *s = sem_sessao ? &VAZIA : &d->sessoes[i];
            mascote_t *m = &g_m[i];
            m->alvo = s->estado;

            const char *txt = s->detalhe[0] ? s->detalhe : NOME[s->estado];
            if (strncmp(txt, m->ult_detalhe, sizeof(m->ult_detalhe)) != 0) {
                snprintf(m->ult_detalhe, sizeof(m->ult_detalhe), "%s", txt);
                lv_label_set_text(m->detalhe, txt);
            }
            if (strncmp(s->projeto, m->ult_projeto, sizeof(m->ult_projeto)) != 0) {
                snprintf(m->ult_projeto, sizeof(m->ult_projeto), "%s", s->projeto);
                lv_label_set_text(m->projeto, s->projeto);
            }
        }
    } else {
        char tmp[36];
        /* A hora muda uma vez por minuto; a consulta acontece 100 vezes nesse
         * intervalo. Sem guarda, 100 invalidacoes para o mesmo texto. */
        static char ult_hora[8], ult_dia[20];
        if (strcmp(d->hora, ult_hora) != 0) {
            snprintf(ult_hora, sizeof(ult_hora), "%s", d->hora);
            lv_label_set_text(g_hora, d->hora);
        }
        if (strcmp(d->dia, ult_dia) != 0) {
            snprintf(ult_dia, sizeof(ult_dia), "%s", d->dia);
            lv_label_set_text(g_dia, d->dia);
        }
        if (d->tem_tempo) {
            /* ARMADILHA DO C: \x consome todos os dígitos hex seguintes.
             * Em "%d\xC2\xB0C" o 'C' é hex válido e some junto com o grau.
             * Fechar o literal antes do 'C' encerra o escape. */
            static int ult_t = -999, ult_hi = -999, ult_lo = -999;
            if (d->temp != ult_t || d->temp_max != ult_hi || d->temp_min != ult_lo) {
                ult_t = d->temp; ult_hi = d->temp_max; ult_lo = d->temp_min;
                snprintf(tmp, sizeof(tmp), "%d\xC2\xB0" "C", d->temp);
                lv_label_set_text(g_temp, tmp);
                lv_label_set_text(g_cond, d->condicao);
                snprintf(tmp, sizeof(tmp), "max %d\xC2\xB0   min %d\xC2\xB0",
                         d->temp_max, d->temp_min);
                lv_label_set_text(g_maxmin, tmp);
            }
            if (strcmp(d->icone, g_icone_atual) != 0) {
                snprintf(g_icone_atual, sizeof(g_icone_atual), "%s", d->icone);
                montar_icone(d->icone);
            }
        }
    }

    /* —— painel de limites ——
     * Com guarda de mudanca. Sem ela reescreviamos 4 barras x 4 rotulos a
     * cada consulta (600ms), cada lv_label_set_text invalidando area, tudo
     * isso SEGURANDO o mutex do LVGL. A task do LVGL, que e quem le o touch,
     * ficava sem rodar — e o deslize demorava segundos para pegar. */
    uint32_t assinatura = (uint32_t) d->qtd_limites * 2654435761u;
    for (int i = 0; i < d->qtd_limites && i < MAX_BARRAS; i++) {
        const fg_limite_t *b = &d->limites[i];
        assinatura = assinatura * 31u + (uint32_t) b->pct;
        assinatura = assinatura * 31u + (uint32_t) b->ativo;
        for (const char *c = b->rotulo; *c; c++) assinatura = assinatura * 31u + (uint8_t) *c;
        for (const char *c = b->reseta; *c; c++) assinatura = assinatura * 31u + (uint8_t) *c;
        for (const char *c = b->gravidade; *c; c++) assinatura = assinatura * 31u + (uint8_t) *c;
    }
    assinatura = assinatura * 31u + (uint32_t)(d->limites_idade_s / 60);

    static uint32_t ult_assinatura = 0;
    if (assinatura != ult_assinatura) {
        ult_assinatura = assinatura;

        for (int i = 0; i < MAX_BARRAS; i++) {
            if (i >= d->qtd_limites) {
                lv_label_set_text(g_bar_rotulo[i], "");
                lv_label_set_text(g_bar_pct[i], "");
                lv_label_set_text(g_bar_reset[i], "");
                lv_obj_add_flag(g_bar[i], LV_OBJ_FLAG_HIDDEN);
                continue;
            }
            const fg_limite_t *b = &d->limites[i];
            lv_obj_remove_flag(g_bar[i], LV_OBJ_FLAG_HIDDEN);

            lv_color_t cor = lv_color_make(95, 207, 142);
            if (!strcmp(b->gravidade, "warning"))  cor = lv_color_make(232, 193, 90);
            if (!strcmp(b->gravidade, "critical")) cor = lv_color_make(232,  98, 74);

            char tmp[40];
            lv_label_set_text(g_bar_rotulo[i], b->rotulo);
            lv_obj_set_style_text_color(g_bar_rotulo[i],
                b->ativo ? lv_color_make(232, 238, 246) : lv_color_make(140, 150, 164), 0);

            snprintf(tmp, sizeof(tmp), "%d%%", b->pct);
            lv_label_set_text(g_bar_pct[i], tmp);
            lv_obj_set_style_text_color(g_bar_pct[i], cor, 0);

            lv_bar_set_value(g_bar[i], b->pct, LV_ANIM_OFF);
            lv_obj_set_style_bg_color(g_bar[i], cor, LV_PART_INDICATOR);

            if (b->reseta[0]) {
                snprintf(tmp, sizeof(tmp), "resets in %s", b->reseta);
                lv_label_set_text(g_bar_reset[i], tmp);
            } else {
                lv_label_set_text(g_bar_reset[i], "");
            }
        }

        char fr[48];
        if (d->limites_idade_s < 0) snprintf(fr, sizeof(fr), "limits unavailable");
        else snprintf(fr, sizeof(fr), "%d min ago", d->limites_idade_s / 60);
        lv_label_set_text(g_frescor, fr);
        lv_obj_set_style_text_color(g_frescor,
            d->limites_idade_s > 900 ? lv_color_make(232, 193, 90)
                                     : lv_color_make(120, 128, 140), 0);
    }

    bsp_display_unlock();
}
