# mTALKIE

Extract, play and export the voice lines of LucasArts SCUMM "talkie" CD games on macOS.

## About

mTALKIE opens the speech files of the CD versions of Indiana Jones and the Fate of Atlantis, Day of the Tentacle and
Sam & Max Hit the Road (`MONSTER.SOU`, or the `.SO3` / `.SOG` / `.SOF` files compressed by the ScummVM tools), and the
speech bank of the Monkey Island Special Editions (`Speech.xwb`) the iMUSE archives of The Dig (`DIGVOICE.BUN`), and the `RESOURCE.AUD` of Sierra SCI32 CD games such as Space Quest 6. It lists every line with its spoken text, length and
waveform, plays it, and exports all lines or a selection as WAV, AIFF or FLAC. Native
Swift, no ffmpeg or other dependency. Original files are never modified.

- Authors: Starbudweiser & Claude Code (Anthropic)
- License: MIT, © 2026 Starbudweiser
- Provided as is, without warranty. Use it with your own copies of the games.
- Not affiliated with LucasArts, Lucasfilm Games or the ScummVM project.
- Part of the DESKTOP MAC TOOLKIT. See the app's **mTALKIE › About mTALKIE** menu.

## Features

- Drag and drop a voice file, or a game folder (`MONSTER.*` is found automatically).
- Thousands of lines in a fast list: number, waveform, length, sample rate and offset in the original `.SOU`
  (the reference used by the game scripts and by ScummVM).
- Spoken text of each line, read from the game scripts (`ATLANTIS.001`…) or, for the Special Editions, from
  `speech.info` in English, French, Italian, German or Spanish; line names from `SpeechCues.xsb`. The Dig: English text
  from `DIG.LA1` and the translation from `LANGUAGE.BND`. Sierra: text from the game's message resources, lines named
  room_noun_verb_condition_sequence from its audio maps.
- Play with a double-click or Space; drag a line to the Finder to get a WAV.
- Export all or the selection: 8-bit WAV (bit-exact copy of the original samples), 16-bit AIFF or FLAC; file name pattern
  with `{file}`, `{n}`, `{offset}`, `{text}` and `{name}`; one subfolder per game.
- French, English, Spanish and Italian interface. Automatic updates from the GitHub releases.

## Format notes

A `.SOU` file is a `SOU ` header followed, for each line, by a `VCTL` block (lip-sync data) and a Creative Voice file
(`Creative Voice File\x1a`, 8-bit unsigned PCM, sample rate = 1 000 000 / (256 − divisor)). The compressed `.SO3` / `.SOG`
/ `.SOF` files start with a big-endian index (original offset, data offset, lip-sync size, compressed size) followed by
the MP3 / Ogg Vorbis / FLAC streams. Full Throttle, The Dig and The Curse of Monkey Island use other formats (`.BUN`).

## Build

```bash
./build_app.sh            # builds, signs and installs mTALKIE.app
DEV=1 ./build_app.sh      # development edition (fr.stephan.mtalkie.dev)
tests/run_tests.sh        # engine tests (synthetic SOU, compressed formats, translations)
```

Requires macOS 15 on Apple silicon.

## Support

mTALKIE is free. If it is useful to you, you can [support the project](https://github.com/sponsors/starbudweiser).

---

*Français :* mTALKIE extrait, écoute et exporte les voix des jeux LucasArts SCUMM en version CD (fichiers `.SOU`,
`.SO3`, `.SOG`, `.SOF`) des éditions spéciales de Monkey Island (`Speech.xwb`) de The Dig (`DIGVOICE.BUN`) et des jeux Sierra en CD comme Space Quest 6 (`RESOURCE.AUD`), avec le texte de chaque réplique,, en WAV, AIFF ou FLAC. Aucun fichier d'origine n'est modifié. Fait partie du DESKTOP MAC TOOLKIT.
