#!/bin/zsh
# Compile et lance les tests du moteur. Argument facultatif : chemin d'un vrai MONSTER.SOU (ou .SO3/.SOG/.SOF).
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${TMPDIR:-/tmp}/mtalkie-tests"
swiftc -O -swift-version 5 -target arm64-apple-macos15 -o "$BIN" tests/main.swift Sources/Formats.swift Sources/Audio.swift Sources/L10n.swift Sources/Texts.swift Sources/Xact.swift Sources/Bun.swift Sources/Sierra.swift Sources/Grime.swift Sources/GGPack.swift Sources/Sword1.swift Sources/Aufs.swift Sources/Bs2.swift Sources/Queen.swift Sources/Telltale.swift Sources/BlowfishTables.swift Sources/Trek.swift Sources/Acmp.swift Sources/Unity.swift Sources/Build.swift Sources/FsbVorbisHeaders.swift Sources/CastingLink.swift
REAL="${1:-/Volumes/SAMSUNG T7/JEUX/SCUMMVM/Indiana Jones and the Fate of Atlantis/MONSTER.SOU}"
if [ -f "$REAL" ]; then "$BIN" "$REAL"; else "$BIN"; fi
