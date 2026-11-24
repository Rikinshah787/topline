#!/bin/zsh
# One-time setup: creates a local self-signed code-signing certificate ("Topline Local Signing")
# in your login keychain. build.sh signs the app with it, so macOS keeps the Accessibility
# permission across rebuilds (ad-hoc signing gives every build a new identity).
#
# Undo any time:  security delete-identity -c "Topline Local Signing" ~/Library/Keychains/login.keychain-db
set -euo pipefail
NAME="Topline Local Signing"

if security find-identity -p codesigning | grep -q "$NAME"; then
    echo "\"$NAME\" already exists — nothing to do."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/c.cnf" <<EOF
[req]
distinguished_name=dn
prompt=no
x509_extensions=ext
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/k.pem" -out "$TMP/c.pem" -days 3650 -config "$TMP/c.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/k.pem" -in "$TMP/c.pem" -out "$TMP/s.p12" -passout pass:tmp -name "$NAME" 2>/dev/null \
  || openssl pkcs12 -export -legacy -inkey "$TMP/k.pem" -in "$TMP/c.pem" -out "$TMP/s.p12" -passout pass:tmp -name "$NAME"
security import "$TMP/s.p12" -k ~/Library/Keychains/login.keychain-db -P tmp -T /usr/bin/codesign

echo "Created \"$NAME\". Now run ./build.sh, then grant Accessibility one last time."
