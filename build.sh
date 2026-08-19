#!/bin/bash
# Baut LocalFlow und packt es als .app-Bundle (nötig für Mikrofon- und
# Bedienungshilfen-Berechtigungen). Kein Xcode erforderlich, nur die CLT.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/LocalFlow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LocalFlow "$APP/Contents/MacOS/LocalFlow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Mit dem lokalen Zertifikat signieren (scripts/make_signing_cert.sh), damit
# die TCC-Freigaben (Mikrofon, Bedienungshilfen) Rebuilds überleben. Eine
# Ad-hoc-Signatur bindet die Freigaben an den Hash des Binaries — nach jedem
# Build wären sie weg.
CERT_NAME="LocalFlow Signing"
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    codesign --force --sign "$CERT_NAME" "$APP"
else
    echo "WARNUNG: Zertifikat \"$CERT_NAME\" fehlt — signiere ad-hoc." >&2
    echo "         TCC-Freigaben gehen dann bei jedem Build verloren." >&2
    echo "         Einmalig anlegen mit: ./scripts/make_signing_cert.sh" >&2
    codesign --force --sign - "$APP"
fi

echo ""
echo "Fertig: $APP"
echo "Starten mit: open $APP"
