/* Interface da Fagulha — separada da rede de propósito, para poder
 * exercitar a tela sem depender de WiFi nenhum. */
#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Os mesmos sete estados que o bridge emite em /state.
 * A ordem importa: ui_estado_de_texto() faz busca linear por nome. */
typedef enum {
    FG_OCIOSO = 0,
    FG_TRABALHANDO,
    FG_FERRAMENTA,
    FG_PERGUNTANDO,
    FG_ESPERANDO,
    FG_CONCLUIDO,
    FG_ERRO,
    FG_SEM_REDE,      /* interno: ainda não conectou */
    FG_QTD
} fg_estado_t;

/* Uma barra de limite da assinatura (vem de cachedUsageUtilization). */
typedef struct {
    char  rotulo[24];
    int   pct;
    char  reseta[8];
    char  gravidade[10];
    bool  ativo;
} fg_limite_t;

/* Quantas sessões do Claude cabem na tela ao mesmo tempo. Acima disso os
 * mascotes ficariam pequenos demais para comunicar qualquer coisa. */
#define FG_MAX_SESSOES 4

/* Uma sessão do Claude Code = um mascote. */
typedef struct {
    fg_estado_t estado;
    char        detalhe[40];   /* "Bash", "approve plan", "Deploy +1"… */
    char        projeto[28];
    char        modelo[24];
    int         idade_s;
} fg_sessao_t;

typedef struct {
    fg_sessao_t sessoes[FG_MAX_SESSOES];
    int         qtd_sessoes;

    fg_limite_t limites[4];
    int         qtd_limites;
    int         limites_idade_s;  /* -1 = indisponível */
    int         bateria_pct;      /* -1 = desconhecida */

    /* —— modo repouso ——
     * Mascote parado não informa nada. Depois de `repouso_s` sem nenhum
     * evento do Claude, a tela vira relógio + tempo. */
    char        hora[8];        /* "18:08" — já formatado pelo bridge */
    char        dia[20];        /* "Fri 14 Aug" */
    int         idade_s;        /* silêncio desde o último evento; -1 = nenhum */
    int         repouso_s;      /* limiar; 0 desliga o modo repouso */
    bool        tem_tempo;
    int         temp, temp_max, temp_min;
    char        condicao[24];   /* "partly cloudy" */
    char        icone[12];      /* "sun","moon","cloud","rain","storm","snow","cloudsun","cloudmoon" */
} fg_dados_t;

/* Constrói a tela. Precisa ser chamada com o mutex do LVGL tomado. */
void ui_criar(void);

/* Atualiza a tela. Toma o mutex sozinha — pode ser chamada de qualquer task. */
void ui_atualizar(const fg_dados_t *d);

/* Converte o campo "st" do JSON para o enum. Desconhecido -> FG_OCIOSO. */
fg_estado_t ui_estado_de_texto(const char *s);

#ifdef __cplusplus
}
#endif
