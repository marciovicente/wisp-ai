#!/bin/bash
#
# Desenha os oito estados do mascote num PNG e abre.
#
#   ./mac/preview.sh
#
# Para mexer no personagem: edite mac/Sources/Mascote.swift, rode isto, olhe.
# Ciclo de uns cinco segundos, sem abrir o app.
#
# Onde mexer, do que mais muda para o que menos muda:
#
#   EstadoMascote.expressao   sobrancelha, boca, olhar e abertura por estado.
#                             É aqui que a emoção mora. Sobrancelha sozinha
#                             carrega mais que todo o resto somado.
#   EstadoMascote.cores       o gradiente do corpo (topo, base).
#   corpoPath()               a silhueta. Mudar isto muda o personagem.
#   chamaPath()               a fagulha que flutua acima da cabeça.
#   desenharBoca()            as sete bocas.

set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAIDA="${1:-$AQUI/build/mascote.png}"
mkdir -p "$(dirname "$SAIDA")"

swiftc -O -target arm64-apple-macosx14.0 \
    -o "$AQUI/build/preview" \
    "$AQUI/Preview/main.swift" "$AQUI/Sources/Mascote.swift"

"$AQUI/build/preview" "$SAIDA"
open "$SAIDA"
