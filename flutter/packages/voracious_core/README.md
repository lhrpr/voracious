# voracious_core

Platform-independent core of Voracious. Pure Dart — no Flutter, no `dart:io`,
no UI — so everything here runs under `dart test` on any machine.

```sh
dart pub get
dart analyze
dart test
```

## What it does

- **Subtitles.** SRT, WebVTT and ASS/SSA parsing, markup cleaning (including
  ASS vector drawing commands, which leak coordinate soup into the text if you
  strip tags with regular expressions), format sniffing, charset detection.
- **Annotated text.** An immutable string carrying nesting ranged annotations
  over its *code points* — words, dictionary forms, furigana, highlights — with
  a generic tree walk that renders to widgets, to Anki bracket notation, or to
  plain text.
- **Japanese.** Kana classification and conversion, and furigana alignment:
  splitting a token's reading across its written form so 引っ越し renders as
  引[ひ]っ越[こ]し rather than as one span.
- **Language.** ISO 639 tables, subtitle file name tag parsing, and script-first
  language detection.
- **Library.** Collection scanning over a filesystem interface: video/subtitle
  pairing, `Subs/` folders, season directories, anime-style flat numbering,
  release-group clutter.
- **Study modes.** The four modes as a headless state machine, driven only by
  position updates and user intents.
- **Playback.** The `MediaPlayer` interface, and the mpv client protocol as
  data: option profiles per platform, command building, property parsing, and
  an event-to-state reducer.
- **Dictionaries.** Yomichan/Yomitan term bank indexing and Japanese
  deinflection.
- **Anki.** AnkiConnect client and card building.
- **Settings and licensing.** Preferences, profile persistence, and the
  third-party notices the LGPL position requires.

## Public API

```dart
import 'package:voracious_core/voracious_core.dart';       // everything above
import 'package:voracious_core/voracious_core_io.dart';    // dart:io adapters
```

The `_io` library is separate so the core library itself has no platform
imports.

## Interfaces the host implements

`MediaFileSystem`, `Tokenizer`, `CharsetDecoder`, `MediaPlayer`,
`AudioClipExtractor`, `AnkiTransport`, `KeyValueStore`. Each has an in-memory or
`dart:io` implementation for tests. See the top-level
[README](../../README.md#platform-seams) for why each one is a seam.

## Regenerating the language table

`lib/src/language/language_table.dart` is generated from the Electron app's
copy of the ISO 639-3 registry:

```sh
dart run tool/generate_language_table.dart
```
