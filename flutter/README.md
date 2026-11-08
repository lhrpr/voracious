# Voracious — Flutter/Dart core

A cross-platform rewrite of Voracious on Flutter, with playback provided by
libmpv through [media_kit](https://pub.dev/packages/media_kit).

A pure-Dart core holds everything that can be verified without a screen, a
codec, or a device, and a desktop application renders it. On macOS that app
plays video, runs the study modes and shows several subtitle tracks at once.

## Why the split

The parts of a language-learning video player that are actually hard are not the
parts that need a UI:

- deciding where a word's reading attaches to its written form,
- deciding *when* to pause so a learner hears the whole line,
- reading a subtitle file whose encoding nobody declared,
- working out that 24 files in a directory are one series and not 24 titles.

All of that is pure logic, and all of it is under test here. The UI, when it
arrives, renders `StudySessionSnapshot` and forwards key presses; it holds no
rules of its own.

## Packages

| Package | What it is | Depends on |
|---|---|---|
| [`voracious_core`](packages/voracious_core) | Pure Dart. No Flutter, no `dart:io`, no UI. | `collection`, `meta`, `path` |
| [`voracious_app`](apps/voracious_app) | The macOS application. Renders core's decisions and forwards intents; holds no study logic. | `flutter`, all of the above |

`voracious_core.dart` is the public API; `voracious_core_io.dart` adds the
`dart:io` implementations (`LocalFileSystem`, `IoAnkiTransport`) separately, so
the core library itself stays free of platform imports.

## What is in core

```
lib/src/
  text/          annotated text: ranged, nesting annotations over code points
  subtitles/     SRT, WebVTT, ASS/SSA parsers; markup cleaning; format sniffing
  encoding/      charset detection and decoding
  cues/          time-indexed cue set with binary-search navigation
  japanese/      kana classification and conversion; furigana alignment
  analysis/      tokeniser interface; tokens -> annotated text
  language/      ISO 639 tables; script-based detection; file name language tags
  library/       filesystem interface; collection scanning; subtitle loading
  player/        MediaPlayer interface, playback state, mpv protocol and options
  study/         the study modes, as a headless state machine
  dictionary/    Yomichan/Yomitan index; Japanese deinflection
  anki/          AnkiConnect client; card building
  settings/      preferences, profile, key/value persistence
  licensing/     third-party notices and the source offer
```

### Platform seams

Everything platform-bound sits behind an interface that the host app implements:

| Interface | Implemented by | Why it is not in core |
|---|---|---|
| `MediaFileSystem` | `LocalFileSystem`, or a SAF/content-URI adapter on Android | Android hands out content URIs, not paths |
| `Tokenizer` | MeCab, Sudachi, or a Kuromoji port | The dictionary is tens of MB; packaging it is a per-platform decision |
| `CharsetDecoder` | the OS text converters | Shift_JIS and friends are tens of thousands of table entries the platform already ships |
| `MediaPlayer` | `MediaKitPlayer` in the app | And something else entirely on a platform that will not run native code |
| `AudioClipExtractor` | platform encoder | Encoding is where patent exposure lives; it stays off the playback path |
| `AnkiTransport` | `IoAnkiTransport` | Keeps `dart:io` out of core |
| `KeyValueStore` | SQLite, SharedPreferences, a file | Every platform already has one |

Detection logic — which encoding, which language, which cue — stays in core,
because that is the part worth testing. Byte tables and system calls do not.

## Study modes

The four modes from the Electron app, ported behaviour-for-behaviour into
`StudySession`:

| Mode | Behaviour |
|---|---|
| Manual | All tracks shown; number keys toggle each. Nothing pauses. |
| Quick Check | Tracks hidden. Continue pauses and reveals one track, then another, then resumes. |
| Listening | Pauses shortly before each line ends. Replay, reveal, continue. |
| Reading | Pauses as each new line starts. Read it, then continue to hear it. |

The subtleties are the reason this is a state machine and not a widget: the
display is held on the line that triggered a pause rather than following the
playhead past it; auto-pause stands down while seeking; a jump into a line has
to pause explicitly because it skipped the moment that would have triggered one.
All of that is covered in `test/study_session_test.dart`.

## Licensing

Voracious is personal and open source, with no release planned, so the app uses
media_kit's stock GPL libmpv as-is. Core still carries an LGPL guard
(`validateLgplSafety`) and third-party notices from when a proprietary release
was on the table; nothing in the app depends on them any more.

## Working on it

The Dart SDK is enough for core; the app needs Flutter and CocoaPods.

```sh
cd packages/voracious_core
dart pub get
dart analyze          # must be clean
dart test             # 343 tests
```

The app is in `apps/voracious_app`. `flutter test` there runs the widget tests,
plus an end-to-end suite against a real engine when a system libmpv is
installed (`brew install mpv`). Video output needs a real embedder:
`flutter test integration_test -d macos`.

To regenerate the ISO 639 table from the Electron app's copy:

```sh
cd packages/voracious_core
dart run tool/generate_language_table.dart
```

## Target platforms

Windows, macOS, Android (including Google TV, Android TV, Fire TV), iOS and
tvOS all run this code unchanged; only the `MediaFileSystem` and `Tokenizer`
implementations differ. `MpvTuning.cheapTvBox` exists for the $40 Amlogic and
Rockchip boxes, where CPU headroom is the constraint that matters.

Tizen and webOS will not run native code at all, under any licence, so they
remain a separate project if they are ever justified — see the cross-platform
section of the root licensing notes. Nothing in core assumes otherwise: it is
pure Dart, and the seams above are where a different engine would attach.

## Not done yet

- Windows, Linux, Android and iOS builds. media_kit covers playback and video
  on all of them, so what's left is platform setup and per-platform UI.
- A Japanese tokeniser implementation. The interface, the token-to-annotation
  pipeline and the furigana alignment are all here and tested; what is missing
  is the backend and its dictionary.
- Platform `CharsetDecoder` implementations for the CJK legacy encodings.
  Detection works today; decoding falls back to Windows-1252 with a low
  confidence the UI can surface.
- ZIP reading for Yomichan dictionary import. The index and lookup are here and
  tested; they take decoded JSON.
- An `AudioClipExtractor` implementation, for Anki audio.
