# voracious_app

The desktop application (macOS so far). UI only: it renders what `voracious_core` decides and
forwards intents back to it.

That division is not a style preference. `StudySession` decides which subtitle
lines are on screen and when playback should stop; this package decides what
that looks like. When something here appears to be making a study decision, it
is forwarding one — `continueStudy()`, `toggleTrackHidden(i)` and the rest are
pass-throughs whose meaning depends on the current mode.

## Running it

```sh
flutter run -d macos
```

Playback is [media_kit](https://pub.dev/packages/media_kit), which bundles a
stock libmpv into the app. Nothing needs installing beyond Flutter and
CocoaPods. The first macOS build downloads that libmpv from GitHub; if
`pod install` fails under Homebrew's Ruby, run it with `LANG=en_US.UTF-8`.

Debug builds run **unsandboxed** so a collection folder anywhere on disk can be
read without a security-scoped bookmark. Release builds keep the sandbox.

Voracious is personal and open source, so the stock GPL libmpv is fine.

## Layout

```
lib/
  main.dart                    entry point; opens storage, loads the profile
  src/
    state/
      library_controller.dart  collections, scanning, resume positions
      player_controller.dart   owns the engine and the study session
    screens/
      library_screen.dart      collections and titles
      player_screen.dart       playback, subtitles, keyboard
      settings_screen.dart     every stored preference; saves as it changes
      about_screen.dart        third-party notices and the source offer
    widgets/
      annotated_text_view.dart AnnotatedText -> widgets, with furigana
      subtitle_stack.dart      the study subtitle display
      transport_bar.dart       seek bar and controls
    storage/
      file_key_value_store.dart JSON file under Application Support
```

### Reading state, not mirroring it

`PlayerController` exposes `playback` and `snapshot` as getters that read the
engine and the session directly, and uses their streams only to decide *when*
to rebuild. Mirroring stream values into fields looks equivalent and is not: a
keypress changes the session synchronously and returns, while stream delivery
is a microtask later, so a mirrored copy is stale for exactly the frame the
user is looking at.

## Keyboard

| Key | Action |
|---|---|
| Space | Play / pause |
| ↓ | Continue — reveal the next track, or resume |
| ↑ | Replay the current line |
| ← / → | Previous / next line |
| 1…9 | Toggle one track (manual mode) |
| R | Reveal everything |
| L | Loop the current line / clear it |
| H | Keyboard help |
| Esc | Back to the library |

The down arrow being the single "continue" key is deliberate: in every mode it
means "I am done with this line", and the mode decides whether that reveals
another track or resumes playback. One key to learn, not four behaviours.

## Tests

```sh
flutter test
```

`widgets_test.dart` covers the two places the UI makes a rendering decision of
its own — the annotation walk, and the study display, where a hidden track has
to keep its space so revealing one does not shift the others.

`player_controller_test.dart` runs the controllers against a real engine and a
real file: a folder scanned off disk, subtitles decoded and analysed, and the
study modes driven by genuine position updates. `flutter test` runs on the host
VM, where media_kit's bundled libmpv isn't available, so these tests need a
system copy (`brew install mpv`) and skip themselves without one.

Video output needs a real embedder:

```sh
flutter test integration_test -d macos
```

runs the controllers inside an app build and checks that media_kit's video
controller starts against the running engine, that a texture reaches the widget
tree, and that closing the screen mid-playback doesn't crash.

## Video output

`PlayerController` creates a media_kit `VideoController` before opening the
file, and the player screen shows it with `Video`, with media_kit's own
controls and subtitles turned off. Voracious draws its own subtitle tracks on
top.

Two things are easy to trip over:

- media_kit sets the video output up after the next frame is drawn, and
  `open()` waits for that. The app is always drawing, so this never shows up
  there; a test without a screen has to pump frames while `start()` runs.
- Losing video is not losing the app. If the video controller can't be
  created, the reason is recorded in `videoOutputError` and playback carries on
  with audio, subtitles and every study mode. A file with no video track gets a
  plain "Audio only".

## Not done yet

- Dictionary lookup on word tap. `AnnotatedTextView` already reports the lemma
  of a tapped word; nothing consumes it yet, and there is no tokeniser for
  Japanese, so words are not yet segmented.
- Anki export. Its settings (`AnkiExportSettings`) are stored but not yet
  on the settings screen.
- Security-scoped bookmarks, so a collection folder survives a relaunch under
  the sandbox.
