/// A subtitle line with each word coloured by its status, as Lute and LingQ
/// colour a page: blue for words the collection doesn't have yet, red through
/// pale green for statuses 1–5, and nothing for known or ignored words.
library;

import 'package:flutter/material.dart';
import 'package:voracious_core/voracious_core.dart';

/// Lute's default status colours, so a word looks the same in both programs.
Color? vocabStatusColor(VocabStatus? status, {required bool inCollection}) =>
    switch (status) {
      null when !inCollection => const Color(0xFFADDFF4),
      // In the collection but never rated: still being met, so still blue,
      // a shade lighter to show it has been saved.
      null => const Color(0xFFD5F0FA),
      VocabStatus.s1 => const Color(0xFFF5B8A9),
      VocabStatus.s2 => const Color(0xFFF5CCA9),
      VocabStatus.s3 => const Color(0xFFF5E1A9),
      VocabStatus.s4 => const Color(0xFFF5F3A9),
      VocabStatus.s5 => const Color(0xFFDDFFDD),
      VocabStatus.known || VocabStatus.ignored => null,
    };

class VocabLineView extends StatelessWidget {
  const VocabLineView({
    super.key,
    required this.text,
    required this.tokens,
    required this.style,
    this.onTap,
  });

  final String text;
  final List<VocabToken> tokens;
  final TextStyle style;

  /// Called with the word and where it was clicked, in global coordinates.
  final void Function(VocabToken token, Rect wordRect)? onTap;

  @override
  Widget build(BuildContext context) {
    // Offsets are in code points; strings index by UTF-16 unit.
    final codePoints = text.runes.toList();
    String slice(int from, int to) => String.fromCharCodes(
          codePoints.sublist(
              from.clamp(0, codePoints.length), to.clamp(0, codePoints.length)),
        );

    final spans = <InlineSpan>[];
    var at = 0;
    for (final token in tokens) {
      if (token.start < at || token.start >= codePoints.length) continue;
      if (token.start > at) {
        spans.add(TextSpan(text: slice(at, token.start)));
      }
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: _Word(
          text: slice(token.start, token.end),
          token: token,
          style: style,
          onTap: onTap,
        ),
      ));
      at = token.end;
    }
    if (at < codePoints.length) {
      spans.add(TextSpan(text: slice(at, codePoints.length)));
    }

    return Text.rich(
      TextSpan(style: style, children: spans),
      textAlign: TextAlign.center,
    );
  }
}

class _Word extends StatelessWidget {
  const _Word({
    required this.text,
    required this.token,
    required this.style,
    this.onTap,
  });

  final String text;
  final VocabToken token;
  final TextStyle style;
  final void Function(VocabToken token, Rect wordRect)? onTap;

  @override
  Widget build(BuildContext context) {
    final color = vocabStatusColor(
      token.displayStatus,
      inCollection: token.word != null,
    );
    // Dark text on the pale highlight; the shadow that keeps white text
    // readable over the picture would only smudge it.
    final wordStyle = color == null
        ? style
        : style.copyWith(color: Colors.black87, shadows: const []);

    return MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap == null
            ? null
            : () {
                final box = context.findRenderObject()! as RenderBox;
                final origin = box.localToGlobal(Offset.zero);
                onTap!(token, origin & box.size);
              },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          decoration: color == null
              ? null
              : BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(4),
                ),
          child: Text(text, style: wordStyle),
        ),
      ),
    );
  }
}
