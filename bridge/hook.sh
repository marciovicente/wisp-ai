#!/bin/bash
# Encaminha eventos de hook do Claude Code para o bridge do mascote.
#
# REGRA DE OURO: isto roda no caminho crítico de cada tool call. Nunca pode
# atrasar nem bloquear o Claude. Se o bridge estiver fora do ar, falha em
# ~200ms e segue em silêncio — nada de retry, nada de stderr.
#
# (É precisamente esse cuidado que falta no ~/.masko-desktop/hooks/hook-sender,
#  que faz retry por ~2s a cada evento mesmo com o servidor morto.)

INPUT=$(cat 2>/dev/null)

curl -s -X POST \
  -H 'Content-Type: application/json' \
  -d "$INPUT" \
  --connect-timeout 0.2 \
  --max-time 0.6 \
  http://127.0.0.1:4666/hook >/dev/null 2>&1

# Sempre 0: um hook que retorna erro pode interferir na sessão.
exit 0
