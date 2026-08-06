# voracious_app

The macOS application. UI only: it renders what `voracious_core` decides and
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

libmpv must be present. On a development machine:

```sh
brew install mpv
```

Debug builds run **unsandboxed**, for one specific reason: a sandboxed process
may not `dlopen` a library outside its own bundle, so it cannot load the libmpv
installed on your machine. Release builds keep the sandbox and load an LGPL
libmpv bundled in `Contents/Frameworks` — see [the build
recipe](../../docs/lgpl-mpv-build.md). Bundling Homebrew's mpv instead would be
a licensing error, not a shortcut: that is a default GPL build.

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

`player_controller_test.dart` runs the controllers against a real libmpv and a
real file: a folder scanned off disk, subtitles decoded and analysed, and the
study modes driven by genuine position updates from the engine. It skips itself
when no libmpv is installed.

Video output is invisible to all of that, because `flutter test` has no
platform side: `VideoOutput.create` throws `MissingPluginException`, the
controller records it as a reason and carries on. That is the behaviour to
have, and it means the ordinary suite cannot tell a working renderer from an
absent one. So:

```sh
flutter test integration_test -d macos
```

runs the same controllers on a real embedder and checks that a render context
is created against the running engine, that a texture reaches the widget tree,
and that tearing the screen down in the order the app actually uses does not
take libmpv with it.

## Video output

There is a picture. It comes from
[`voracious_video`](../../packages/voracious_video), which attaches an
`mpv_render_context` to the engine `PlayerController` already owns and draws it
into a `FlutterTexture` through an IOSurface.

Two orderings in `PlayerController` are load-bearing and easy to undo by
accident:

- The output is created **before** `player.open(...)`. `vo=libmpv` has nowhere
  to draw until a render context exists.
- It is disposed **before** the player. The render context holds the engine
  handle.

Losing video is not losing the app. If the render context cannot be created —
most likely a libmpv without the OpenGL render API compiled in — the failure is
recorded in `videoOutputError`, playback carries on with audio, subtitles and
every study mode intact, and the player screen shows the reason over a black
surface. The same path handles a file with no video track, which is a normal
thing to open and gets a plain "Audio only".

## Not done yet

- Dictionary lookup on word tap. `AnnotatedTextView` already reports the lemma
  of a tapped word; nothing consumes it yet, and there is no tokeniser for
  Japanese, so words are not yet segmented.
- Anki export, and the settings screen for the preferences the core already
  stores.
- Security-scoped bookmarks, so a collection folder survives a relaunch under
  the sandbox.
