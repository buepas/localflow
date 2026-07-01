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

# Ad-hoc-Signatur, damit macOS die TCC-Berechtigungen stabil zuordnen kann.
codesign --force --sign - "$APP"

echo ""
echo "Fertig: $APP"
echo "Starten mit: open $APP"
