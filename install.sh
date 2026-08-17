#!/bin/bash
#
# Instala a Fagulha no seu Mac.
#
#   curl -fsSL https://raw.githubusercontent.com/USUARIO/fagulha/main/install.sh | bash
#   ou, com o repositório já clonado:  ./install.sh
#
# POR QUE COMPILAR EM VEZ DE BAIXAR UM .DMG
# -----------------------------------------
# App baixado da internet recebe a marca de quarentena do macOS, e sem uma
# assinatura de desenvolvedor (US$ 99/ano) o sistema recusa abrir com um aviso
# de malware. App compilado na própria máquina nunca recebe essa marca.
# Compilar aqui não é preguiça de empacotar — é o que remove a fricção.
#
# O que este script faz, em ordem:
#   1. confere os pré-requisitos
#   2. compila o Fagulha.app
#   3. instala em ~/Applications
#   4. oferece registrar os hooks do Claude Code (com backup, e você aprova)
#
# Não instala nada global, não pede sudo, não mexe em configuração do sistema.

set -euo pipefail

AZUL=$'\033[34m'; VERDE=$'\033[32m'; AMARELO=$'\033[33m'; ZERA=$'\033[0m'
passo() { echo "${AZUL}==>${ZERA} $*"; }
ok()    { echo "${VERDE} ok${ZERA} $*"; }
aviso() { echo "${AMARELO} !${ZERA} $*"; }
morre() { echo "erro: $*" >&2; exit 1; }

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESTINO="$HOME/Applications"

# ————————————————————————————————— 1. pré-requisitos

passo "conferindo o ambiente"

[[ "$(uname -s)" == "Darwin" ]] || morre "isto é um app de macOS."

versao="$(sw_vers -productVersion)"
maior="${versao%%.*}"
(( maior >= 14 )) || morre "precisa de macOS 14 ou mais novo (você tem $versao).
   O app usa MenuBarExtra do SwiftUI, que não existe antes disso."
ok "macOS $versao"

if ! command -v swiftc >/dev/null 2>&1; then
    morre "não achei o swiftc.
   Instale as ferramentas de linha de comando e rode de novo:

       xcode-select --install

   São ~700MB e vêm da Apple. Sem elas não há como compilar."
fi
ok "swift $(swiftc --version 2>/dev/null | head -1 | sed 's/.*version //;s/ .*//')"

# O bridge roda no Python que vem com o macOS. É de propósito: assim ele não
# quebra quando você trocar de versão no asdf/pyenv/homebrew.
[[ -x /usr/bin/python3 ]] || morre "não achei /usr/bin/python3."
ok "python $(/usr/bin/python3 --version 2>&1 | sed 's/Python //')"

command -v dns-sd >/dev/null 2>&1 || aviso "sem dns-sd: a placa vai precisar do IP fixo."

# ————————————————————————————————— 2. compilar

passo "compilando"
if pgrep -f "Fagulha.app/Contents/MacOS/Fagulha" >/dev/null 2>&1; then
    aviso "o Fagulha estava aberto — fechando para poder substituir"
    pkill -f "Fagulha.app/Contents/MacOS/Fagulha" || true
    sleep 2
fi
"$RAIZ/mac/build.sh" >/dev/null || morre "a compilação falhou. Rode ./mac/build.sh para ver o erro."
ok "Fagulha.app compilado"

# ————————————————————————————————— 3. instalar

passo "instalando em $DESTINO"
mkdir -p "$DESTINO"
rm -rf "$DESTINO/Fagulha.app"
cp -R "$RAIZ/mac/build/Fagulha.app" "$DESTINO/Fagulha.app"
ok "$DESTINO/Fagulha.app"

# Primeira leitura da config gera o token e descobre sua cidade pelo IP.
/usr/bin/python3 "$RAIZ/bridge/config.py" | sed 's/^/   /'

# ————————————————————————————————— 4. hooks do Claude Code

echo
passo "hooks do Claude Code"
echo "   Sem eles o mascote não sabe o que o Claude está fazendo — é o que"
echo "   alimenta os status. O instalador acrescenta os nossos e não toca"
echo "   nos que você já tem, guardando uma cópia do arquivo antes."
echo
if [[ -t 0 ]]; then
    read -r -p "   registrar os hooks agora? [S/n] " resp
    resp="${resp:-S}"
else
    resp="n"   # rodando por pipe: não mexemos em config sem alguém pra aprovar
    aviso "rodando sem terminal interativo — pulando os hooks"
fi

if [[ "$resp" =~ ^[SsYy]$ ]]; then
    /usr/bin/python3 "$RAIZ/bridge/install_hook.py" || aviso "os hooks falharam; rode bridge/install_hook.py depois"
else
    echo "   pulado. Quando quiser:  /usr/bin/python3 bridge/install_hook.py"
fi

# ————————————————————————————————— pronto

cat <<FIM

${VERDE}pronto.${ZERA}

  abra:   open ~/Applications/Fagulha.app

  O ícone aparece na barra de menu. O bridge sobe junto com o app e cai
  junto quando você fecha — nada fica rodando pelas suas costas.

  Marque "Abrir no login" no painel se quiser que ele suba sozinho.

  Só o app já mostra consumo e sessões. Para a placa Waveshare mostrar o
  mascote, veja firmware/README.md.
FIM
