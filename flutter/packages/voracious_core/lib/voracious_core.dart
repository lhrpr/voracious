/// Platform-independent core of Voracious.
///
/// Pure Dart: no Flutter, no `dart:io`, no UI. Everything here can be exercised
/// by `dart test` on any machine, which is the point — the parts of a video
/// study app that are actually hard (subtitle parsing, furigana alignment,
/// study-mode timing, library organisation) should not need a screen or a
/// codec to verify.
///
/// Platform-bound pieces live behind interfaces that the host application
/// implements: [MediaFileSystem] for storage, [Tokenizer] for morphological
/// analysis, [CharsetDecoder] for legacy encodings, [MediaPlayer] for
/// playback, [AnkiTransport] for HTTP, and [KeyValueStore] for persistence.
/// `dart:io` implementations of the first two are in `voracious_core_io.dart`.
library;

// Text and annotation
export 'src/text/annotated_text.dart';
export 'src/text/code_points.dart';

// Subtitles
export 'src/subtitles/ass_parser.dart';
export 'src/subtitles/srt_parser.dart';
export 'src/subtitles/subtitle_cue.dart';
export 'src/subtitles/subtitle_format.dart';
export 'src/subtitles/subtitle_text.dart';
export 'src/subtitles/timestamps.dart';
export 'src/subtitles/vtt_parser.dart';

// Character encoding
export 'src/encoding/charset.dart';
export 'src/encoding/charset_detector.dart';
export 'src/encoding/text_decoder.dart';

// Cues
export 'src/cues/cue_index.dart';

// Japanese
export 'src/japanese/furigana.dart';
export 'src/japanese/kana.dart';

// Analysis
export 'src/analysis/annotation_builder.dart';
export 'src/analysis/language_token.dart';
export 'src/analysis/text_analyzer.dart';
export 'src/analysis/tokenizer.dart';

// Languages
export 'src/language/language_detector.dart';
export 'src/language/language_table.dart';
export 'src/language/subtitle_language_tag.dart';

// Media library
export 'src/library/episode_parsing.dart';
export 'src/library/file_system.dart';
export 'src/library/media_library.dart';
export 'src/library/media_scanner.dart';
export 'src/library/subtitle_loader.dart';

// Playback
export 'src/player/media_player.dart';
export 'src/player/media_track.dart';
export 'src/player/mpv/mpv_options.dart';
export 'src/player/mpv/mpv_protocol.dart';
export 'src/player/mpv/mpv_state_machine.dart';
export 'src/player/mpv/mpv_track_list.dart';
export 'src/player/playback_state.dart';

// Study modes
export 'src/study/study_session.dart';
export 'src/study/subtitle_mode.dart';
export 'src/study/track_ordering.dart';

// Dictionaries
export 'src/dictionary/deinflector.dart';
export 'src/dictionary/dictionary.dart';
export 'src/dictionary/yomichan_dictionary.dart';

// Anki export
export 'src/anki/anki_connect.dart';
export 'src/anki/card_builder.dart';

// Settings and persistence
export 'src/settings/key_value_store.dart';
export 'src/settings/preferences.dart';
export 'src/settings/profile_repository.dart';

// Licensing
export 'src/licensing/third_party_notices.dart';

// Utilities
export 'src/util/uid.dart';
