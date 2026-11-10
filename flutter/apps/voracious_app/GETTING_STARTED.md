# Running Voracious and loading a video

## Prerequisites

- macOS
- [Flutter](https://docs.flutter.dev/get-started/install/macos) (with Xcode)
- CocoaPods: `brew install cocoapods`

## Run the app

From this directory (`flutter/apps/voracious_app`):

```sh
flutter pub get
flutter run -d macos
```

The first build downloads media_kit's bundled libmpv, so it takes a while.
Nothing else needs installing.

If `pod install` fails under Homebrew's Ruby, retry with:

```sh
LANG=en_US.UTF-8 flutter run -d macos
```

## Load a video

Voracious loads **folders** ("collections"), not individual files.

1. Put your video in a folder, together with any subtitle files:

   ```
   MyVideos/
     Show Name/
       Show Name - 01.mkv
       Show Name - 01.ja.srt
       Show Name - 01.en.srt
   ```

   - Video formats: `mkv, mp4, m4v, avi, mov, webm, ts, m2ts, mts, wmv`
   - Subtitle formats: `srt, vtt, ass, ssa`. Text subtitle tracks embedded
     in an MKV are extracted automatically.
   - Name subtitles after the video, with a language tag (`.ja.srt`,
     `.en.srt`) so each track is labelled correctly. A subtitle that matches
     no video is listed under "subtitle files matched no video".

2. In the app, click **Add folder** and choose the folder (`MyVideos` above,
   or `Show Name` directly). It is scanned and shown in the library.
3. Select the collection, then click a video or episode to play it.

Each row shows how many subtitle tracks the video has and in which languages.
Playback resumes from where you left off.

## Controls

| Key | Action |
|---|---|
| Space | Play / pause |
| ↓ | Continue: reveal the next track, or resume |
| ↑ | Replay the current line |
| ← / → | Previous / next line |
| 1…9 | Toggle one subtitle track (manual mode) |
| R | Reveal everything |
| L | Loop the current line / clear it |
| H | Keyboard help |
| Esc | Back to the library |

## Troubleshooting

- **No video, but audio and subtitles work:** the reason is recorded in
  `videoOutputError`; playback and study modes continue regardless.
- **"No videos found in this folder":** check the file extensions above.
- **Collection gone after relaunch in a release build:** release builds are
  sandboxed and don't yet keep security-scoped bookmarks, so re-add the
  folder. Debug builds (`flutter run`) are unsandboxed and aren't affected.
