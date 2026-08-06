/// Renders an [AnnotatedText] as Flutter widgets.
///
/// `AnnotatedText.render` is a generic tree walk that takes two callbacks: one
/// to turn a code point into a piece, one to wrap a run of pieces in an
/// annotation. The same walk produces Anki fields and plain-text exports in
/// core; here the pieces are widgets. This is the whole reason annotations are
/// stored as ranges over code points rather than as marked-up strings — the
/// renderer never has to parse anything.
library;

import 'package:flutter/material.dart';
import 'package:voracious_core/voracious_core.dart';

/// A single subtitle line, with furigana above the kanji that carry it.
///
/// Ruby text cannot be expressed as an [InlineSpan] — it needs a column with
/// the reading above the base text, and the reading must not widen the line's
/// layout — so the walk builds widgets and lays them out with a [Wrap].
class AnnotatedTextView extends StatelessWidget {
  const AnnotatedTextView({
    super.key,
    required this.text,
    required this.style,
    this.showRuby = true,
    this.onWordTap,
  });

  final AnnotatedText text;
  final TextStyle style;

  /// Furigana are the point of the app for Japanese, and noise for a language
  /// that has no readings; the preference controls it.
  final bool showRuby;

  /// Called with the lemma (or surface form) of a tapped word, once a
  /// dictionary is wired up.
  final void Function(String word)? onWordTap;

  @override
  Widget build(BuildContext context) {
    final pieces = text.render<Widget>(
      transformChar: (character, _) => Text(character, style: style),
      wrap: (annotation, inner) => switch (annotation) {
        RubyAnnotation(:final text) when showRuby => [
            _Ruby(reading: text, style: style, children: inner),
          ],
        HighlightAnnotation() => [
            DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withValues(
                      alpha: 0.28,
                    ),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: inner),
            ),
          ],
        WordAnnotation(:final lemma) when onWordTap != null => [
            _Tappable(
              onTap: () => onWordTap!(lemma ?? _plainTextOf(inner)),
              children: inner,
            ),
          ],
        // Ruby with readings turned off, and words with no tap handler, still
        // have to contribute their inner pieces or the text would vanish.
        _ => inner,
      },
    );

    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: pieces,
    );
  }

  static String _plainTextOf(List<Widget> pieces) =>
      pieces.whereType<Text>().map((piece) => piece.data ?? '').join();
}

/// Base text with its reading above it.
class _Ruby extends StatelessWidget {
  const _Ruby({
    required this.reading,
    required this.style,
    required this.children,
  });

  final String reading;
  final TextStyle style;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rubyStyle = style.copyWith(
      fontSize: (style.fontSize ?? 24) * 0.45,
      height: 1,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The reading sits in its own zero-flex row so a long reading over a
        // single kanji does not stretch the line.
        Text(reading, style: rubyStyle, maxLines: 1),
        Row(mainAxisSize: MainAxisSize.min, children: children),
      ],
    );
  }
}

class _Tappable extends StatelessWidget {
  const _Tappable({required this.onTap, required this.children});

  final VoidCallback onTap;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        ),
      );
}
