#!/bin/bash
# Prepara um conjunto de mascotes: tira o fundo e alinha os oito estados.
#
#   ./mac/normalizar-mascote.sh [pasta]
#   (padrão: ~/.fagulha/mascotes/terminal)
#
# Gera uma subpasta `normalizado/`. Confira e, se gostar, mova por cima dos
# originais. Nunca sobrescreve sem você olhar antes.
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$AQUI/build"
swiftc -O -target arm64-apple-macosx14.0 -o "$AQUI/build/normalizar" "$AQUI/Normalizar/main.swift"
"$AQUI/build/normalizar" "${1:-$HOME/.fagulha/mascotes/terminal}"
