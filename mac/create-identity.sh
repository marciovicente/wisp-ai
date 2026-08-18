#!/bin/bash
#
# Creates a self-signed code signing identity on this machine.
#
# WHY
# ---
# Without an identity the build uses an ad-hoc signature, which is derived from
# the CONTENT of the binary. Every rebuild changes the signature, and macOS
# ties keychain permission to the signature — so each build becomes "a
# different app" and the previous "Always Allow" stops counting. In practice:
# it asks for your password forever.
#
# With a certificate the signature derives from the CERTIFICATE, not the
# content. It stays stable across builds, and the permission survives.
#
# It is free and local: no Apple account, no notarization. Good for this
# machine, not for distribution.
#
# Undo:  security delete-certificate -c "Wisp Dev" ~/Library/Keychains/login.keychain-db

set -euo pipefail
NAME="Wisp Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "==> '$NAME' already exists, nothing to do"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

echo "==> generating the certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/k.pem" -out "$TMP/c.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
# A real password, not an empty one. With `-passout pass:` the import fails
# with "MAC verification failed ... (wrong password?)" — a message that points
# at the wrong thing: the problem is the empty-password bundle, not the
# password. It protects a temporary file that dies at the end of this script.
openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/k.pem" -in "$TMP/c.pem" \
    -name "$NAME" -passout pass:wisp 2>/dev/null
chmod 600 "$TMP"/*

echo "==> importing into your keychain (may ask for authorization)"
# -T lets codesign use the key without asking every time.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P wisp -T /usr/bin/codesign -A >/dev/null

echo "==> marking it as trusted for code signing"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/c.pem" 2>/dev/null \
    || echo "   (could not set trust; codesign usually accepts it anyway)"

echo
security find-identity -v -p codesigning | sed 's/^/  /'
