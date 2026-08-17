#!/bin/bash
#
# Monta o Fagulha.app sem projeto do Xcode — só swiftc e um bundle na mão.
#
# Por que sem projeto: um .xcodeproj é um arquivo enorme, gerado, difícil de
# revisar e que ninguém edita a mão. Aqui o build inteiro cabe nesta tela e
# você consegue ler o que ele faz.
#
# O bridge Python vai DENTRO do bundle. Assim o app é autocontido: pode ir
# pra /Applications sem levar o repositório junto.
#
# Uso:  ./mac/build.sh [--rodar]

set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$AQUI")"
APP="$AQUI/build/Fagulha.app"
ALVO="arm64-apple-macosx14.0"   # onChange de 2 params exige 14; MenuBarExtra, 13

echo "==> limpando"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bridge"

echo "==> compilando Swift"
swiftc -O \
    -target "$ALVO" \
    -o "$APP/Contents/MacOS/Fagulha" \
    "$AQUI"/Sources/*.swift

echo "==> empacotando"
cp "$AQUI/Info.plist" "$APP/Contents/Info.plist"

# Lista NEGATIVA de propósito: copiamos tudo e excluímos o que é de bancada.
# Com lista positiva, cada módulo novo precisava ser lembrado aqui — e um
# esquecimento não dá erro de build, só um app que sobe e morre no import.
# Aconteceu exatamente isso com o config.py.
BANCADA="provision_wifi.py install_hook.py capture_imu.py"
for f in "$RAIZ"/bridge/*.py; do
    nome="$(basename "$f")"
    case " $BANCADA " in *" $nome "*) continue ;; esac
    cp "$f" "$APP/Contents/Resources/bridge/$nome"
done

# Assinatura ad-hoc: sem ela o macOS trata o app como danificado depois da
# primeira cópia. Não substitui uma assinatura de desenvolvedor, mas basta
# pra rodar na sua própria máquina.
# Assinatura ad-hoc deriva do CONTEÚDO do binário: muda a cada recompilação,
# e como o macOS amarra a permissão do chaveiro à assinatura, cada build vira
# "outro app" e o "Always Allow" anterior perde a validade. Com uma identidade
# própria a assinatura deriva do CERTIFICADO e fica estável entre builds.
# Crie a sua com ./mac/criar-identidade.sh — é local e de graça.
IDENT="Fagulha Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENT"; then
    echo "==> assinando como '$IDENT'"
    codesign --force --sign "$IDENT" --timestamp=none "$APP" 2>&1 | sed 's/^/    /' || true
else
    echo "==> assinando (ad-hoc — o chaveiro vai perguntar a cada build)"
    codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /' || true
fi

echo
echo "pronto: $APP"
du -sh "$APP" | sed 's/^/    /'

if [[ "${1:-}" == "--rodar" ]]; then
    echo "==> abrindo"
    pkill -f "Fagulha.app/Contents/MacOS/Fagulha" 2>/dev/null || true
    sleep 1
    open "$APP"
fi
