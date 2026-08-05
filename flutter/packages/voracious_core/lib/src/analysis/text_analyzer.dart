/// Routes text to the right tokeniser for its language.
library;

import '../text/annotated_text.dart';
import 'annotation_builder.dart';
import 'language_token.dart';
import 'tokenizer.dart';

/// Holds the tokenisers available to this process and produces annotated text.
///
/// A subtitle track's language is detected once at load time; every cue in it
/// then goes through the tokeniser registered for that language. Unregistered
/// languages fall through to plain text, so an unsupported track still plays
/// and still displays — it just has no word boundaries to tap.
class TextAnalyzer {
  TextAnalyzer({Map<String, AnnotationOptions>? optionsByLanguage})
      : _options = {
          // Japanese is the only language where readings are worth rendering.
          'jpn': const AnnotationOptions(),
          ...?optionsByLanguage,
        };

  final Map<String, Tokenizer> _tokenizers = {};
  final Map<String, AnnotationOptions> _options;

  /// Registers [tokenizer] for its declared language, replacing any previous
  /// registration.
  void register(Tokenizer tokenizer) =>
      _tokenizers[tokenizer.languageCode] = tokenizer;

  /// Sets the annotation options used for [languageCode] (ISO 639-3).
  void setOptions(String languageCode, AnnotationOptions options) =>
      _options[languageCode] = options;

  /// Languages with a registered tokeniser.
  Set<String> get supportedLanguages => _tokenizers.keys.toSet();

  bool canAnalyze(String? languageCode) =>
      languageCode != null && _tokenizers.containsKey(languageCode);

  Tokenizer? tokenizerFor(String? languageCode) =>
      languageCode == null ? null : _tokenizers[languageCode];

  /// Loads the backend for [languageCode] if there is one.
  ///
  /// Worth calling before a batch of [analyze] calls: a dictionary-backed
  /// tokeniser can take seconds to initialise, and the caller usually wants
  /// that cost accounted for as "loading subtitles" rather than charged to the
  /// first cue.
  Future<void> prepare(String? languageCode) async {
    final tokenizer = tokenizerFor(languageCode);
    if (tokenizer != null && !tokenizer.isReady) await tokenizer.ensureReady();
  }

  /// Analyses [text] as [languageCode], returning annotated text.
  ///
  /// Falls back to unannotated text when no tokeniser is registered.
  Future<AnnotatedText> analyze(String text, String? languageCode) async {
    final tokenizer = tokenizerFor(languageCode);
    if (tokenizer == null || text.trim().isEmpty) {
      return AnnotatedText.plain(text);
    }

    if (!tokenizer.isReady) await tokenizer.ensureReady();

    final List<LanguageToken> tokens;
    try {
      tokens = await tokenizer.tokenize(text);
    } on Object {
      // A tokeniser failure must not cost the user the subtitle line.
      return AnnotatedText.plain(text);
    }

    return buildAnnotatedText(
      text,
      tokens,
      options: _options[languageCode] ?? AnnotationOptions.wordsOnly,
    );
  }

  /// Analyses many lines, reporting progress as a fraction in `[0, 1]`.
  ///
  /// Loading a feature-length subtitle track means a few thousand calls into
  /// the tokeniser; the caller wants to show a progress bar rather than freeze.
  Future<List<AnnotatedText>> analyzeAll(
    List<String> lines,
    String? languageCode, {
    void Function(double progress)? onProgress,
  }) async {
    await prepare(languageCode);

    final results = <AnnotatedText>[];
    for (var i = 0; i < lines.length; i++) {
      results.add(await analyze(lines[i], languageCode));
      onProgress?.call((i + 1) / lines.length);
    }
    return results;
  }
}
