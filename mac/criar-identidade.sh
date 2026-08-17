#!/bin/bash
#
# Cria uma identidade de assinatura própria, autoassinada, nesta máquina.
#
# POR QUE
# -------
# Sem identidade, o build usa assinatura ad-hoc, que é derivada do CONTEÚDO do
# binário. Toda recompilação muda a assinatura, e o macOS amarra a permissão do
# chaveiro à assinatura — então cada build vira "outro app" e o "Always Allow"
# anterior deixa de valer. Na prática: ele pede a senha para sempre.
#
# Com um certificado, a assinatura deriva do CERTIFICADO, não do conteúdo. Ela
# fica estável entre builds, e a permissão sobrevive.
#
# É de graça e local: nada de conta Apple, nada de notarização. Serve para esta
# máquina, não para distribuir.
#
# Desfazer:  security delete-certificate -c "Fagulha Dev" ~/Library/Keychains/login.keychain-db

set -euo pipefail
NOME="Fagulha Dev"
CHAVEIRO="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NOME" "$CHAVEIRO" >/dev/null 2>&1; then
    echo "==> '$NOME' já existe, nada a fazer"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

echo "==> gerando o certificado"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/k.pem" -out "$TMP/c.pem" \
    -subj "/CN=$NOME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
# Senha real, nao vazia. Com `-passout pass:` a importacao falha com
# "MAC verification failed ... (wrong password?)" — mensagem que aponta para
# o lugar errado: o problema e o pacote com senha vazia, nao a senha.
# Ela protege um arquivo temporario que morre no fim deste script.
openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/k.pem" -in "$TMP/c.pem" \
    -name "$NOME" -passout pass:fagulha 2>/dev/null
chmod 600 "$TMP"/*

echo "==> importando no seu chaveiro (pode pedir autorização)"
# -T libera o codesign a usar a chave sem perguntar toda vez.
security import "$TMP/id.p12" -k "$CHAVEIRO" -P fagulha -T /usr/bin/codesign -A >/dev/null

echo "==> marcando como confiável para assinatura de código"
security add-trusted-cert -r trustRoot -p codeSign -k "$CHAVEIRO" "$TMP/c.pem" 2>/dev/null \
    || echo "   (não consegui marcar a confiança; o codesign costuma aceitar mesmo assim)"

echo
security find-identity -v -p codesigning | sed 's/^/  /'
