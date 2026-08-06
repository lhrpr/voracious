# Voracious — Flutter/Dart core

A cross-platform rewrite of Voracious on Flutter, with playback provided by a
dynamically linked LGPL build of libmpv.

Two pure-Dart packages hold everything that can be verified without a screen, a
codec, or a device, and a macOS application renders it. The one piece still
missing is video output: getting decoded frames onto the screen needs
`mpv_render_context_*` drawing into a texture the toolkit owns, which is native
code rather than Dart. Everything else — playback, the study modes, subtitles,
the library — runs today.

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
| [`voracious_mpv`](packages/voracious_mpv) | `dart:ffi` bindings to libmpv and a `MediaPlayer` on top. Pure Dart — loads the library at runtime. | `ffi`, `voracious_core` |
| [`voracious_video`](packages/voracious_video) | Video output: an mpv render context drawn into a Flutter texture. macOS native. | `flutter` |
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
| `MediaPlayer` | `voracious_mpv` | And something else entirely on a platform that will not run native code |
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

Playback is a dynamically linked LGPL build of mpv. The build recipe, the
components LGPL mode removes, and the distribution obligations are in
[`docs/lgpl-mpv-build.md`](docs/lgpl-mpv-build.md).

Two things enforce it rather than merely documenting it:

- `validateLgplSafety` rejects any mpv configuration naming a component that an
  LGPL build does not have. Every shipped platform configuration is asserted
  against it in `mpv_test.dart`, and `MpvPlayer.create` re-checks at startup.
- The tests assert that every copyleft entry in `thirdPartyNotices` is
  dynamically linked and carries a corresponding-source URL.

## Working on it

The Dart SDK is enough; Flutter is not needed for anything in this directory.

```sh
cd packages/voracious_core
dart pub get
dart analyze          # must be clean
dart test             # 343 tests
```

Same for `packages/voracious_mpv`, which additionally has an integration suite
that calls into a real libmpv. Install one (`brew install mpv`, `apt install
libmpv2`) and it runs with the rest; without one it skips itself.

That suite is worth having rather than assuming. On first run against a real
library it found three defects that no amount of pure-Dart testing could have
shown: `gpu-api=opengl` in the Apple configuration, which current mpv rejects
outright and which stopped the engine from starting at all; a library search
that silently fell back to the system libmpv when an explicit bundled path
failed, which for a shipped build means running an unknown and quite possibly
GPL library; and a use-after-free on teardown, where the handle was destroyed
while the event-pump thread was still inside `mpv_wait_event` — an abort on
roughly one in four closes.

The macOS app is in `apps/voracious_app`; `flutter test` there runs both widget
tests and an end-to-end suite against a real engine.

Video output is the one thing `flutter test` cannot reach, because under it
there is no platform side at all. It has two checks of its own:
`packages/voracious_video/tool/render_probe.sh` renders a few seconds into an
IOSurface with no Flutter involved and reports what landed in it, and
`apps/voracious_app/integration_test` needs a real embedder (`flutter test
integration_test -d macos`). The first one has already earned its keep: the
render was upside down, and no assertion anybody would think to write would
have said so.

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

- Video output on any platform but macOS. `voracious_video` holds the macOS
  renderer; the Dart API above it is platform-neutral, so the work per platform
  is a renderer rather than a redesign.
- The Windows, Android and iOS applications. Only the UI layer is missing —
  every platform seam below it is implemented and tested.
- A Japanese tokeniser implementation. The interface, the token-to-annotation
  pipeline and the furigana alignment are all here and tested; what is missing
  is the backend and its dictionary.
- Platform `CharsetDecoder` implementations for the CJK legacy encodings.
  Detection works today; decoding falls back to Windows-1252 with a low
  confidence the UI can surface.
- ZIP reading for Yomichan dictionary import. The index and lookup are here and
  tested; they take decoded JSON.
- An `AudioClipExtractor` implementation, for Anki audio.
