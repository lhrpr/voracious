/// Aligns a word's reading against its written form to place furigana.
///
/// A tokeniser gives a whole-token reading: 引っ越し → ヒッコシ. Rendering that
/// as one ruby span over the whole token is legible but crude — it repeats the
/// okurigana the learner can already read. What we want is `引[ひ]っ越[こ]し`,
/// which needs the reading split at the kana the surface form already shows.
///
/// The original Voracious did this with a character diff. That works for simple
/// cases and misplaces the split when a kana in the okurigana also occurs
/// inside a kanji's reading. This is a direct segmentation instead: split the
/// surface into kana and non-kana runs, anchor the kana runs in the reading,
/// and give each non-kana run whatever falls between its anchors.
library;

import 'package:meta/meta.dart';

import '../text/annotated_text.dart';
import '../text/code_points.dart';
import 'kana.dart';

/// Which kana furigana is rendered in.
enum RubyStyle { hiragana, katakana }

/// A stretch of a word's surface form, with the reading that belongs to it.
@immutable
class FuriganaSegment {
  const FuriganaSegment({
    required this.cpBegin,
    required this.cpEnd,
    required this.surface,
    this.ruby,
  });

  /// Code point offsets into the surface form.
  final int cpBegin;
  final int cpEnd;

  /// The surface text of this segment.
  final String surface;

  /// The reading to render above [surface], or null when the surface already
  /// shows its own reading (a kana run).
  final String? ruby;

  bool get needsRuby => ruby != null;

  @override
  bool operator ==(Object other) =>
      other is FuriganaSegment &&
      other.cpBegin == cpBegin &&
      other.cpEnd == cpEnd &&
      other.surface == surface &&
      other.ruby == ruby;

  @override
  int get hashCode => Object.hash(cpBegin, cpEnd, surface, ruby);

  @override
  String toString() => ruby == null
      ? 'FuriganaSegment($surface)'
      : 'FuriganaSegment($surface[$ruby])';
}

/// Splits [surface] into segments annotated with the parts of [reading] that
/// belong to them.
///
/// Returns segments covering the whole of [surface] in order. When the reading
/// cannot be aligned — an irregular reading like 大人 → おとな is fine, but
/// 一昨日 → おととい across mixed scripts may not be — the result is a single
/// segment carrying the entire reading, which is always correct if less
/// pretty.
///
/// An empty list means no furigana is needed at all: [surface] is already kana,
/// or the reading matches it exactly.
List<FuriganaSegment> alignFurigana(
  String surface,
  String reading, {
  RubyStyle style = RubyStyle.hiragana,
}) {
  if (surface.isEmpty || reading.isEmpty) return const [];

  final normalizedReading = normalizeKana(reading);
  final normalizedSurface = normalizeKana(surface);

  // The written form already is the reading.
  if (normalizedSurface == normalizedReading) return const [];

  final surfaceChars = toCodePoints(surface);
  final runs = _splitRuns(surfaceChars);

  String styled(String kana) =>
      style == RubyStyle.katakana ? hiraganaToKatakana(kana) : kana;

  List<FuriganaSegment> wholeWord() => [
        FuriganaSegment(
          cpBegin: 0,
          cpEnd: surfaceChars.length,
          surface: surface,
          ruby: styled(normalizedReading),
        ),
      ];

  // No kana to anchor against: one span over everything.
  if (runs.every((r) => !r.isKana)) return wholeWord();
  // All kana but not equal to the reading — nothing sensible to split on.
  if (runs.every((r) => r.isKana)) return wholeWord();

  final aligned = _align(runs, normalizedReading, surfaceChars);
  if (aligned == null) return wholeWord();

  return [
    for (final segment in aligned)
      FuriganaSegment(
        cpBegin: segment.cpBegin,
        cpEnd: segment.cpEnd,
        surface: segment.surface,
        ruby: segment.ruby == null ? null : styled(segment.ruby!),
      ),
  ];
}

/// Builds the ruby annotations for a token at [cpOffset] in a larger text.
///
/// Segments whose surface is already kana produce no annotation.
List<RubyAnnotation> furiganaAnnotations(
  String surface,
  String reading, {
  int cpOffset = 0,
  RubyStyle style = RubyStyle.hiragana,
}) =>
    [
      for (final segment in alignFurigana(surface, reading, style: style))
        if (segment.needsRuby)
          RubyAnnotation(
            cpBegin: cpOffset + segment.cpBegin,
            cpEnd: cpOffset + segment.cpEnd,
            text: segment.ruby!,
          ),
    ];

/// A maximal run of kana or of non-kana characters in the surface form.
class _Run {
  _Run(this.cpBegin, this.cpEnd, this.isKana, this.text, this.normalized);

  final int cpBegin;
  final int cpEnd;
  final bool isKana;
  final String text;

  /// [text] folded for comparison against the normalised reading.
  final String normalized;

  int get normalizedLength => normalized.runes.length;
}

List<_Run> _splitRuns(List<String> chars) {
  final runs = <_Run>[];
  var start = 0;
  while (start < chars.length) {
    final runIsKana = isKana(chars[start]);
    var end = start + 1;
    while (end < chars.length && isKana(chars[end]) == runIsKana) {
      end++;
    }
    final text = chars.sublist(start, end).join();
    runs.add(_Run(start, end, runIsKana, text, normalizeKana(text)));
    start = end;
  }
  return runs;
}

class _AlignedSegment {
  _AlignedSegment(this.cpBegin, this.cpEnd, this.surface, this.ruby);

  final int cpBegin;
  final int cpEnd;
  final String surface;
  final String? ruby;
}

/// Anchors each kana run in [reading] and hands the gaps to the non-kana runs.
/// Returns null when the runs cannot be anchored, leaving the caller to fall
/// back to a whole-word reading.
List<_AlignedSegment>? _align(
  List<_Run> runs,
  String reading,
  List<String> surfaceChars,
) {
  final readingChars = toCodePoints(reading);
  final segments = <_AlignedSegment>[];

  var low = 0;
  var high = readingChars.length;
  final working = List<_Run>.of(runs);

  // Anchor a trailing kana run against the end of the reading first, so the
  // last non-kana run has a right-hand bound to stop at.
  _Run? trailing;
  if (working.last.isKana) {
    trailing = working.removeLast();
    final tail = trailing.normalized;
    final tailLength = trailing.normalizedLength;
    if (tailLength > high) return null;
    if (readingChars.sublist(high - tailLength).join() != tail) return null;
    high -= tailLength;
  }

  for (var index = 0; index < working.length; index++) {
    final run = working[index];

    if (run.isKana) {
      final length = run.normalizedLength;
      if (low + length > high) return null;
      if (readingChars.sublist(low, low + length).join() != run.normalized) {
        return null;
      }
      segments.add(_AlignedSegment(run.cpBegin, run.cpEnd, run.text, null));
      low += length;
      continue;
    }

    // A non-kana run stops where the next kana run starts in the reading; if
    // it is the last run, it takes everything left.
    final int end;
    if (index + 1 < working.length) {
      final next = working[index + 1];
      // Start the search one past `low`: every kanji run must take at least
      // one mora, which rules out a spurious early match.
      final found = reading.indexOf(
        next.normalized,
        _codePointToCodeUnit(readingChars, low + 1),
      );
      if (found < 0) return null;
      end = _codeUnitToCodePoint(readingChars, found);
      if (end > high) return null;
    } else {
      end = high;
    }

    if (end <= low) return null;
    segments.add(_AlignedSegment(
      run.cpBegin,
      run.cpEnd,
      run.text,
      readingChars.sublist(low, end).join(),
    ));
    low = end;
  }

  // Every mora must have been consumed.
  if (low != high) return null;

  if (trailing != null) {
    segments.add(
      _AlignedSegment(trailing.cpBegin, trailing.cpEnd, trailing.text, null),
    );
  }

  return segments;
}

/// Converts a code point offset into the UTF-16 offset `String.indexOf` wants.
int _codePointToCodeUnit(List<String> chars, int codePointOffset) {
  var units = 0;
  for (var i = 0; i < codePointOffset && i < chars.length; i++) {
    units += chars[i].length;
  }
  return units;
}

/// Inverse of [_codePointToCodeUnit].
int _codeUnitToCodePoint(List<String> chars, int codeUnitOffset) {
  var units = 0;
  for (var i = 0; i < chars.length; i++) {
    if (units >= codeUnitOffset) return i;
    units += chars[i].length;
  }
  return chars.length;
}
