/// Loads a subtitle file all the way to a studyable [CueIndex].
///
/// This is the one place where decoding, parsing, language detection and
/// morphological analysis meet. It is also the slowest operation in the app —
/// a feature-length Japanese track is a few thousand tokeniser calls — so it
/// reports progress and is safe to run in an isolate.
library;

import 'package:meta/meta.dart';

import '../analysis/text_analyzer.dart';
import '../cues/cue_index.dart';
import '../encoding/charset.dart';
import '../encoding/text_decoder.dart';
import '../language/language_detector.dart';
import '../language/language_table.dart';
import '../subtitles/subtitle_cue.dart';
import '../subtitles/subtitle_format.dart';
import 'file_system.dart';
import 'media_library.dart';

/// Where a track's language came from, which decides how much to trust it.
enum LanguageSource {
  /// Read from the file name — reliable.
  fileName,

  /// Detected from the text — usually right, occasionally not.
  detected,

  /// Neither worked.
  unknown,
}

/// A subtitle track ready to study.
@immutable
class LoadedSubtitleTrack {
  const LoadedSubtitleTrack({
    required this.id,
    required this.cues,
    required this.languageCode,
    required this.languageSource,
    required this.charset,
    required this.charsetConfidence,
  });

  /// Matches [SubtitleFileRef.id].
  final String id;

  final CueIndex cues;

  /// ISO 639-3, or [undeterminedLanguage].
  final String languageCode;

  final LanguageSource languageSource;

  final Charset charset;
  final double charsetConfidence;

  bool get isEmpty => cues.isEmpty;

  /// English name of [languageCode], for track pickers.
  String get languageDisplayName => languageCode == undeterminedLanguage
      ? 'Unknown'
      : (languageName(languageCode) ?? languageCode);

  @override
  String toString() => 'LoadedSubtitleTrack($id, $languageCode, '
      '${cues.length} cues, ${charset.name})';
}

/// Stages a subtitle load passes through, for progress reporting.
enum SubtitleLoadStage {
  reading,
  decoding,
  parsing,
  detectingLanguage,
  analyzing
}

/// Reads, decodes, parses and analyses subtitle files.
class SubtitleTrackLoader {
  SubtitleTrackLoader({
    required this.fileSystem,
    required this.analyzer,
    this.decoderRegistry,
    this.excludeAssStyles = const {},
  });

  final MediaFileSystem fileSystem;
  final TextAnalyzer analyzer;
  final TextDecoderRegistry? decoderRegistry;

  /// ASS style names to drop as non-dialogue. See
  /// [conventionalNonDialogueStyles].
  final Set<String> excludeAssStyles;

  /// Loads the track [ref] refers to.
  Future<LoadedSubtitleTrack> load(
    SubtitleFileRef ref, {
    void Function(SubtitleLoadStage stage, double progress)? onProgress,
  }) async {
    onProgress?.call(SubtitleLoadStage.reading, 0);
    final bytes = await fileSystem.readBytes(ref.path);

    onProgress?.call(SubtitleLoadStage.decoding, 0);
    final decoded = decodeSubtitleBytes(bytes, registry: decoderRegistry);

    onProgress?.call(SubtitleLoadStage.parsing, 0);
    final cues = parseSubtitles(
      decoded.text,
      ref.format,
      excludeAssStyles: excludeAssStyles,
    ).where((cue) => !cue.isEmpty).toList();

    onProgress?.call(SubtitleLoadStage.detectingLanguage, 0);
    final (languageCode, source) = _resolveLanguage(ref, cues);

    onProgress?.call(SubtitleLoadStage.analyzing, 0);
    final annotated = await analyzer.analyzeAll(
      cues.map((c) => c.text).toList(),
      languageCode == undeterminedLanguage ? null : languageCode,
      onProgress: (progress) =>
          onProgress?.call(SubtitleLoadStage.analyzing, progress),
    );

    return LoadedSubtitleTrack(
      id: ref.id,
      cues: CueIndex([
        for (var i = 0; i < cues.length; i++)
          StudyCue(
            begin: cues[i].begin,
            end: cues[i].end,
            text: annotated[i],
          ),
      ]),
      languageCode: languageCode,
      languageSource: source,
      charset: decoded.charset,
      charsetConfidence: decoded.confidence,
    );
  }

  /// Prefers the file name's language tag, since it is stated rather than
  /// inferred, and falls back to detecting from the text.
  (String, LanguageSource) _resolveLanguage(
    SubtitleFileRef ref,
    List<SubtitleCue> cues,
  ) {
    final tagged = ref.languageCode;
    if (tagged != null) return (tagged, LanguageSource.fileName);

    if (cues.isEmpty) return (undeterminedLanguage, LanguageSource.unknown);

    // A sample from the middle avoids opening credits and translator notes,
    // which are often in a different language from the dialogue.
    final sample = _sampleText(cues);
    final detection = detectLanguage(sample);
    return detection.isUndetermined
        ? (undeterminedLanguage, LanguageSource.unknown)
        : (detection.iso6393, LanguageSource.detected);
  }

  static String _sampleText(List<SubtitleCue> cues) {
    const targetLength = 4000;
    final start = cues.length > 20 ? cues.length ~/ 5 : 0;
    final buffer = StringBuffer();
    for (var i = start; i < cues.length && buffer.length < targetLength; i++) {
      buffer
        ..write(cues[i].text)
        ..write('\n');
    }
    return buffer.toString();
  }
}
