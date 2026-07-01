#!/bin/bash
# Baut ein verteilbares DMG.
#
# Ohne Argumente: ad-hoc-signiertes DMG (Empfänger müssen die App in
# Systemeinstellungen → Datenschutz & Sicherheit → "Dennoch öffnen" freigeben).
#
# Mit Developer-ID + Notarisierung (empfohlen für Verteilung):
#   SIGN_IDENTITY="Developer ID Application: Dein Name (TEAMID)" \
#   NOTARY_PROFILE="localflow" ./release.sh
#
# NOTARY_PROFILE einmalig anlegen mit:
#   xcrun notarytool store-credentials localflow \
#     --apple-id du@example.com --team-id TEAMID --password <app-spezifisches-passwort>
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
APP="build/LocalFlow.app"
DMG="build/LocalFlow-${VERSION}.dmg"

# Icon generieren, falls noch nicht vorhanden
if [[ ! -f Resources/AppIcon.icns ]]; then
    swift scripts/make_icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

./build.sh

# Mit Developer ID neu signieren: Hardened Runtime + Entitlements + Timestamp
# (Voraussetzung für Notarisierung; die Ad-hoc-Signatur aus build.sh wird ersetzt).
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp \
        --entitlements Resources/LocalFlow.entitlements \
        --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"
    echo "Signiert mit: $SIGN_IDENTITY"
else
    echo "WARNUNG: Kein SIGN_IDENTITY gesetzt — DMG ist nur ad-hoc-signiert."
fi

# DMG mit Applications-Verknüpfung bauen
STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "LocalFlow" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --sign "$SIGN_IDENTITY" "$DMG"
fi

# Notarisieren + Ticket antackern, damit Gatekeeper auch offline zufrieden ist
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "Notarisiere (kann ein paar Minuten dauern) …"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "Notarisiert und gestapelt."
fi

echo ""
echo "Fertig: $DMG"
du -h "$DMG"
