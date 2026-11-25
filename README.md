# mTALKIE

Extract, play and export the voice lines of classic adventure games on macOS: LucasArts (SCUMM, iMUSE, GrimE),
Sierra, Revolution, Interplay, Interactive Binary Illusions, Telltale, CrazyBunch and Terrible Toybox.

## About

mTALKIE opens the speech files of these games (drop the file, or simply the game or its folder):

| Game | Files |
|---|---|
| Indiana Jones and the Fate of Atlantis, Day of the Tentacle, Sam & Max Hit the Road (CD) | `MONSTER.SOU`, or `.SO3` / `.SOG` / `.SOF` compressed by the ScummVM tools |
| The Secret of Monkey Island and Monkey Island 2: Special Edition | `audio/Speech.xwb` |
| The Dig | `DIGVOICE.BUN` |
| The Curse of Monkey Island | `RESOURCE/VOXDISK1.BUN`, `VOXDISK2.BUN` |
| Escape from Monkey Island | `voiceAll.m4b`… |
| Sierra SCI32 CD games (Space Quest 6…) | `RESOURCE.AUD` |
| Broken Sword: The Shadow of the Templars (ScummVM edition) | `speech/speech1.clv`, `speech2.clv` (also `.clf` / `.cl3`) |
| Broken Sword – Shadow of the Templars: Reforged | `english.osa`, `french.osa`… |
| Broken Sword 2: Remastered | `Audio/Speech_english.dat`… (voices only for now) |
| Thimbleweed Park | `ThimbleweedPark.ggpack2` |
| Flight of the Amazon Queen (CD, compressed by the ScummVM tools) | `queen.1c` |
| Tales of Monkey Island (episodes 1 to 5) | `Pack/2_MonkeyIsland10x_pc_voice.ttarch` |
| Star Trek: Judgment Rites (CD) | the CD image `STJR1.dat` (GOG) or the `.VCC` files of the CD |
| Leisure Suit Larry – Wet Dreams Don't Dry, Wet Dreams Dry Twice | the game itself, or `StreamingAssets/localisation/englishvo` (`germanvo`) |

It lists every line with its spoken text, length and
waveform, plays it, and exports all lines or a selection as WAV, AIFF or FLAC. Native
Swift, no ffmpeg or other dependency. Original files are never modified.

- Authors: Starbudweiser & Claude Code (Anthropic)
- License: MIT, © 2026 Starbudweiser
- Provided as is, without warranty. Use it with your own copies of the games.
- Not affiliated with LucasArts, Lucasfilm Games, Sierra, Revolution Software, Interplay, Interactive Binary Illusions, Telltale Games, CrazyBunch, Assemble Entertainment, Terrible Toybox or the ScummVM project.
- Part of the DESKTOP MAC TOOLKIT. See the app's **mTALKIE › About mTALKIE** menu.

## Features

- Drag and drop a voice file, a game or its folder: the voice file is found automatically.
- Thousands of lines in a fast list: number, waveform, length, sample rate and offset in the original `.SOU`
  (the reference used by the game scripts and by ScummVM).
- Spoken text of each line, read from the game scripts (`ATLANTIS.001`…) or, for the Special Editions, from
  `speech.info` in English, French, Italian, German or Spanish; line names from `SpeechCues.xsb`. The Dig: English text
  from `DIG.LA1` and the translation from `LANGUAGE.BND`. The Curse of Monkey Island: English text from `COMI.LA1` / `COMI.LA2` and
  the translation from `LANGUAGE.TAB`. Thimbleweed Park: text in English, French, German, Spanish, Italian and Russian from
  `ThimbleweedPark.ggpack1`. Broken Sword: text in English, French, German, Italian, Spanish and Czech from `clusters/text.clu`; Reforged: the same six languages from `text.vt7a`. Broken Sword 2 Remastered: voices only for now. Flight of the Amazon Queen: text of the dialogues, cutscenes and Joe's remarks from `queen.1c`, in the language of the version. Tales of Monkey Island: text in English (and German) with the character of each line, from the episode's `_data.ttarch`. Star Trek: Judgment Rites: English text from the episode files in `TREK2`. Leisure Suit Larry (CrazyBunch): English or German voices, text in up to 8 languages from the game's `databases` and `localisation` bundles. Sierra: text from the game's message resources, lines named
  room_noun_verb_condition_sequence from its audio maps. Escape from Monkey Island: VIMA voices, text from `script.tab`
  (in `artAll.m4b`).
- Play with a double-click or Space; drag a line to the Finder to get a WAV.
- Export all or the selection: 8-bit WAV (bit-exact copy of the original samples), 16-bit AIFF or FLAC; file name pattern
  with `{file}`, `{n}`, `{offset}`, `{text}` and `{name}`; one subfolder per game.
- **Send to mCASTING** (the DESKTOP MAC TOOLKIT voice-casting app): pick lines of one character, name the voice, and
  mTALKIE assembles a clean 15–25 s clip whose reference text comes from the subtitles, ready to clone. Or send a whole
  game's lines (text, speaker guessed from the line names and editable, automatic tags, light AAC audio) to mCASTING's
  searchable line database. Format: mCASTING's `docs/INBOX.md`. Game lines and voices are copyrighted: private use and
  tests only.
- French, English, Spanish and Italian interface. Automatic updates from the GitHub releases.

## Format notes

A `.SOU` file is a `SOU ` header followed, for each line, by a `VCTL` block (lip-sync data) and a Creative Voice file
(`Creative Voice File\x1a`, 8-bit unsigned PCM, sample rate = 1 000 000 / (256 − divisor)). The compressed `.SO3` / `.SOG`
/ `.SOF` files start with a big-endian index (original offset, data offset, lip-sync size, compressed size) followed by
the MP3 / Ogg Vorbis / FLAC streams. Full Throttle uses another format; The Dig and The Curse of Monkey Island are read from their `.BUN` archives.

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

*Français :* mTALKIE extrait, écoute et exporte en WAV, AIFF ou FLAC les voix des jeux d'aventure classiques, avec le
texte de chaque réplique : jeux LucasArts en CD (Indiana Jones and the Fate of Atlantis, Day of the Tentacle, Sam & Max,
`MONSTER.SOU`…), éditions spéciales de Monkey Island (`Speech.xwb`), The Dig (`DIGVOICE.BUN`), The Curse of Monkey Island
(`VOXDISK1.BUN`, `VOXDISK2.BUN`), Escape from Monkey Island (`voiceAll.m4b`), jeux Sierra en CD comme Space Quest 6
(`RESOURCE.AUD`), Broken Sword (version ScummVM `speech1.clv`, Reforged `english.osa`, Broken Sword 2 Remastered
`Speech_english.dat`), Thimbleweed Park (`ThimbleweedPark.ggpack2`) Flight of the Amazon Queen (`queen.1c`) Tales of Monkey Island (`2_MonkeyIsland101_pc_voice.ttarch`…) Star Trek: Judgment Rites (image du CD `STJR1.dat` ou fichiers `.VCC`) et les deux Leisure Suit Larry de CrazyBunch (Wet Dreams Don't Dry, Wet Dreams Dry Twice : voix anglaises et allemandes, textes en 8 langues). Il suffit de glisser le fichier, le jeu ou son dossier.
Aucun fichier d'origine n'est modifié. Fait partie du DESKTOP MAC TOOLKIT.
