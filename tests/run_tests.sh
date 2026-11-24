#!/bin/zsh
# Compile et lance les tests du moteur. Argument facultatif : chemin d'un vrai MONSTER.SOU (ou .SO3/.SOG/.SOF).
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${TMPDIR:-/tmp}/mtalkie-tests"
swiftc -O -swift-version 5 -target arm64-apple-macos15 -o "$BIN" tests/main.swift Sources/Formats.swift Sources/Audio.swift Sources/L10n.swift Sources/Texts.swift
REAL="${1:-/Volumes/SAMSUNG T7/JEUX/SCUMMVM/Atlantis/MONSTER.SOU}"
if [ -f "$REAL" ]; then "$BIN" "$REAL"; else "$BIN"; fi
