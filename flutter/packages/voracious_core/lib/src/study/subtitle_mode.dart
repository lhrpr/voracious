/// The study modes that make this a learning tool rather than a video player.
library;

/// How subtitles are revealed and when playback pauses itself.
enum SubtitleMode {
  /// Every track is shown; the number keys toggle each one. No automatic
  /// pausing.
  manual(
    'manual',
    'Manual',
    'All subtitle tracks are shown. Toggle each one with the number keys. '
        'Nothing pauses automatically.',
  ),

  /// Subtitles stay hidden until asked for, and asking pauses playback.
  quickCheck(
    'qcheck',
    'Quick Check',
    'Subtitles are hidden. Press continue to pause and reveal the first '
        'track, again for each further track, and again to resume. For when '
        'you mostly follow the dialogue and only want to check occasionally.',
  ),

  /// Pauses at the end of each line so you can check what you heard.
  listen(
    'listen',
    'Listening Practice',
    'Subtitles start hidden and playback pauses at the end of each line. '
        'Replay it if you need to, reveal the subtitles to check what you '
        'heard, then continue.',
  ),

  /// Pauses at the start of each line so you can read it before hearing it.
  read(
    'read',
    'Reading Practice',
    'Playback pauses at the start of each new line. Read it, then continue '
        'to hear it spoken and find out whether you read it correctly.',
  );

  const SubtitleMode(this.wireName, this.displayName, this.description);

  /// Stable name used in stored preferences. Matches the values the Electron
  /// app wrote, so an existing profile carries over.
  final String wireName;

  final String displayName;

  /// User-facing explanation of the mode, shown in the help overlay.
  final String description;

  /// True when the mode hides tracks until the user reveals them one at a
  /// time.
  bool get revealsProgressively =>
      this == SubtitleMode.quickCheck || this == SubtitleMode.listen;

  /// True when the mode pauses playback on its own.
  bool get pausesAutomatically =>
      this == SubtitleMode.listen || this == SubtitleMode.read;

  static SubtitleMode byWireName(String name, {SubtitleMode? fallback}) {
    for (final mode in SubtitleMode.values) {
      if (mode.wireName == name) return mode;
    }
    if (fallback != null) return fallback;
    throw ArgumentError.value(name, 'name', 'unknown subtitle mode');
  }
}
