#!/bin/bash
# Legt einmalig ein selbstsigniertes Code-Signing-Zertifikat "LocalFlow Signing"
# im Login-Schlüsselbund an. build.sh signiert damit — dadurch bleiben die
# TCC-Freigaben (Mikrofon, Bedienungshilfen) über Rebuilds hinweg erhalten.
#
# Beim Vertrauens-Schritt und beim ersten Signieren fragt macOS einmal per
# Dialog nach dem Login-Passwort ("Immer erlauben" wählen).
set -euo pipefail

CERT_NAME="LocalFlow Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "Zertifikat \"$CERT_NAME\" existiert bereits — nichts zu tun."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT_NAME
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:FALSE
EOF

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null
openssl pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" -passout pass:localflow -name "$CERT_NAME"

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P localflow -T /usr/bin/codesign
# Dem Zertifikat fürs Code-Signieren vertrauen (macOS fragt hier nach dem Passwort)
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo ""
security find-identity -v -p codesigning | grep "$CERT_NAME" || {
    echo "FEHLER: Identität nicht gefunden — Import fehlgeschlagen?" >&2
    exit 1
}
echo "Fertig. build.sh benutzt das Zertifikat ab jetzt automatisch."
