/// Turns raw subtitle event text into the plain text a learner reads.
///
/// Subtitle files carry three overlapping markup dialects: ASS/SSA override
/// blocks (`{\i1}`), HTML-ish inline tags (`<i>`, `<font color=...>`) that all
/// three formats tolerate, and backslash escapes (`\N`, `\h`). A chain of
/// regular expressions gets most of this but mishandles the cases that matter
/// most — ASS vector drawing commands leak coordinate soup into the text, and a
/// literal `{` in dialogue eats the rest of the line — so this is a scanner.
library;

/// Removes subtitle markup from [raw], returning readable plain text.
///
/// Set [stripOverrideBlocks] to false for formats where `{}` is not markup.
String cleanSubtitleText(String raw, {bool stripOverrideBlocks = true}) {
  final buffer = StringBuffer();
  final chars = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  // ASS drawing mode: after {\p1} the "text" is a sequence of vector drawing
  // commands, and stays that way until {\p0}.
  var drawing = false;
  var i = 0;

  while (i < chars.length) {
    final char = chars[i];

    if (stripOverrideBlocks && char == '{') {
      final close = chars.indexOf('}', i);
      if (close >= 0) {
        final block = chars.substring(i + 1, close);
        final drawingLevel = _drawingLevelOf(block);
        if (drawingLevel != null) drawing = drawingLevel > 0;
        i = close + 1;
        continue;
      }
      // Unclosed brace: not markup, keep it.
    }

    if (drawing) {
      // Drawing commands run until the next override block flips \p back off.
      i++;
      continue;
    }

    if (char == '<') {
      final close = chars.indexOf('>', i);
      if (close >= 0 && _looksLikeTag(chars.substring(i + 1, close))) {
        final tag = chars.substring(i + 1, close).trim().toLowerCase();
        if (tag == 'br' || tag == 'br/' || tag == 'br /') buffer.write('\n');
        i = close + 1;
        continue;
      }
    }

    if (char == r'\' && i + 1 < chars.length) {
      final next = chars[i + 1];
      if (next == 'N' || next == 'n') {
        buffer.write('\n');
        i += 2;
        continue;
      }
      if (next == 'h') {
        buffer.write(' ');
        i += 2;
        continue;
      }
    }

    if (char == '&') {
      final semicolon = chars.indexOf(';', i);
      if (semicolon > i && semicolon - i <= 10) {
        final decoded = _decodeEntity(chars.substring(i + 1, semicolon));
        if (decoded != null) {
          buffer.write(decoded);
          i = semicolon + 1;
          continue;
        }
      }
    }

    buffer.write(char);
    i++;
  }

  return _tidyLines(buffer.toString());
}

/// Returns the argument of a `\p` drawing tag in [block], or null if absent.
int? _drawingLevelOf(String block) {
  final match = RegExp(r'\\p(\d+)').firstMatch(block);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

/// Matches a WebVTT inline cue timing tag such as `<00:01:02.500>`.
final RegExp _vttTimingTag = RegExp(r'^(?:\d+:)?\d{1,2}:\d{1,2}[.,]\d{1,3}$');

/// True when the text between `<` and `>` is plausibly an inline tag rather
/// than dialogue such as `<-- look at that`.
bool _looksLikeTag(String inner) {
  if (inner.isEmpty || inner.contains('\n')) return false;
  final trimmed = inner.startsWith('/') ? inner.substring(1) : inner;
  if (trimmed.isEmpty) return false;
  if (_vttTimingTag.hasMatch(trimmed.trim())) return true;
  final first = trimmed.codeUnitAt(0);
  return (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A);
}

const Map<String, String> _namedEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'lrm': '',
  'rlm': '',
};

String? _decodeEntity(String body) {
  if (body.isEmpty) return null;
  if (body.startsWith('#')) {
    final isHex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
    final digits = isHex ? body.substring(2) : body.substring(1);
    final value = int.tryParse(digits, radix: isHex ? 16 : 10);
    if (value == null || value < 0 || value > 0x10FFFF) return null;
    return String.fromCharCode(value);
  }
  return _namedEntities[body.toLowerCase()];
}

/// Trims trailing whitespace from each line and drops blank leading/trailing
/// lines, without collapsing intentional interior blank lines.
String _tidyLines(String text) {
  final lines = text.split('\n').map((l) => l.trimRight()).toList();
  var start = 0;
  var end = lines.length;
  while (start < end && lines[start].trim().isEmpty) {
    start++;
  }
  while (end > start && lines[end - 1].trim().isEmpty) {
    end--;
  }
  return lines.sublist(start, end).map((l) => l.trimLeft()).join('\n');
}
