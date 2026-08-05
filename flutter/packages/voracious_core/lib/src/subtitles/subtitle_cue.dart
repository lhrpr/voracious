/// The output of every subtitle parser: a timed block of text.
library;

import 'package:meta/meta.dart';

/// One timed subtitle event.
///
/// [text] is already cleaned of markup — override blocks, HTML tags and escape
/// sequences are resolved by the parser, so what is left is what a learner
/// reads. Hard line breaks survive as `\n`.
@immutable
class SubtitleCue {
  const SubtitleCue({
    required this.begin,
    required this.end,
    required this.text,
    this.styleName,
    this.layer = 0,
  });

  final Duration begin;
  final Duration end;
  final String text;

  /// ASS/SSA style name, when the source format has one. Useful for filtering
  /// out signs and karaoke tracks that are not dialogue.
  final String? styleName;

  /// ASS/SSA layer. Zero for formats without layering.
  final int layer;

  Duration get duration => end - begin;

  bool get isEmpty => text.trim().isEmpty;

  SubtitleCue copyWith({Duration? begin, Duration? end, String? text}) =>
      SubtitleCue(
        begin: begin ?? this.begin,
        end: end ?? this.end,
        text: text ?? this.text,
        styleName: styleName,
        layer: layer,
      );

  /// Returns this cue with its timings moved by [offset]; used for subtitle
  /// sync adjustment. Timings are clamped at zero.
  SubtitleCue shifted(Duration offset) {
    final newBegin = begin + offset;
    final newEnd = end + offset;
    return copyWith(
      begin: newBegin.isNegative ? Duration.zero : newBegin,
      end: newEnd.isNegative ? Duration.zero : newEnd,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SubtitleCue &&
      other.begin == begin &&
      other.end == end &&
      other.text == text &&
      other.styleName == styleName &&
      other.layer == layer;

  @override
  int get hashCode => Object.hash(begin, end, text, styleName, layer);

  @override
  String toString() =>
      'SubtitleCue(${begin.inMilliseconds}ms-${end.inMilliseconds}ms, '
      '"${text.replaceAll('\n', r'\n')}")';
}
