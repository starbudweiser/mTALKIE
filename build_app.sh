#!/bin/zsh
# Construit mTALKIE.app (ou, avec DEV=1, « mTALKIE dev.app », identifiant fr.stephan.mtalkie.dev, réglages séparés), la signe
# (certificat local stable) puis l'installe dans ~/Applications/Applications Personnelles.
# NO_INSTALL=1 : ne pas installer ; FORCE=1 : installer même pendant un export.
set -euo pipefail
cd "$(dirname "$0")"
DEST="$HOME/Applications/Applications Personnelles"
if [ -n "${DEV:-}" ]; then NAME="mTALKIE dev"; else NAME="mTALKIE"; fi
APP="$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos15 -o "$APP/Contents/MacOS/mTALKIE" Sources/*.swift
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Descriptions des autorisations dans les 4 langues
for l in fr en es it; do mkdir -p "$APP/Contents/Resources/$l.lproj"; cp "Resources/$l.lproj/InfoPlist.strings" "$APP/Contents/Resources/$l.lproj/InfoPlist.strings"; done
if [ -n "${DEV:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier fr.stephan.mtalkie.dev" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName mTALKIE dev" "$APP/Contents/Info.plist"
fi
SIGN="/Volumes/SKYRIM/TOOLS/MAC/_tools/sign_app.sh"
if [ -x "$SIGN" ]; then "$SIGN" "$APP"; else codesign --force --deep -s - "$APP"; fi
if [ -z "${NO_INSTALL:-}" ] && [ -z "${DEV:-}" ]; then
  mkdir -p "$DEST"
  # Jamais d'installation pendant un export : l'appli installée serait arrêtée en plein travail.
  if [ -z "${FORCE:-}" ] && pgrep -x mTALKIE >/dev/null && [ -f "$HOME/.mtalkie-busy" ]; then
    echo "Export en cours : installation annulée (l'appli compilée est dans $PWD/$APP). FORCE=1 pour passer outre." >&2
    exit 2
  fi
  pkill -x mTALKIE 2>/dev/null || true
  rm -rf "$DEST/$APP"
  cp -R "$APP" "$DEST/$APP"
  echo "Installée : $DEST/$APP"
fi
echo "OK : $APP"
