/// SubRip (`.srt`) parsing.
library;

import 'subtitle_cue.dart';
import 'subtitle_text.dart';
import 'timestamps.dart';

/// Parses SubRip [source] into cues.
///
/// Deliberately forgiving: sequence numbers may be missing, duplicated or out
/// of order, blocks may be separated by more than one blank line, and the
/// decimal separator may be `,` or `.`. Blocks without a timing line are
/// skipped rather than failing the file, because a single malformed block is
/// common in scene releases and losing the other 900 cues would be worse.
List<SubtitleCue> parseSrt(String source) {
  final cues = <SubtitleCue>[];
  final lines = _splitLines(source);

  var i = 0;
  while (i < lines.length) {
    // Skip blank separator lines.
    if (lines[i].trim().isEmpty) {
      i++;
      continue;
    }

    // A block is: optional sequence number, a timing line, then text until a
    // blank line. Find the timing line within the next couple of lines.
    var timingIndex = -1;
    for (var j = i; j < lines.length && j < i + 3; j++) {
      if (lines[j].trim().isEmpty) break;
      if (lines[j].contains('-->')) {
        timingIndex = j;
        break;
      }
    }

    if (timingIndex < 0) {
      // No timing found: drop this block and resynchronise at the next blank.
      while (i < lines.length && lines[i].trim().isEmpty == false) {
        i++;
      }
      continue;
    }

    final timing = _parseTimingLine(lines[timingIndex]);
    i = timingIndex + 1;

    final textLines = <String>[];
    while (i < lines.length && lines[i].trim().isNotEmpty) {
      // Defensive: an unterminated block runs straight into the next cue.
      if (lines[i].contains('-->')) break;
      textLines.add(lines[i]);
      i++;
    }

    if (timing == null) continue;

    final text = cleanSubtitleText(textLines.join('\n'));
    if (text.isEmpty) continue;

    cues.add(SubtitleCue(begin: timing.$1, end: timing.$2, text: text));
  }

  return cues;
}

/// Parses `00:00:01,000 --> 00:00:04,000` into a begin/end pair.
(Duration, Duration)? _parseTimingLine(String line) {
  final arrow = line.indexOf('-->');
  if (arrow < 0) return null;
  final begin = tryParseTimestamp(line.substring(0, arrow));
  // Anything after the end timestamp is a positioning directive; ignore it.
  final end = tryParseTimestamp(line.substring(arrow + 3));
  if (begin == null || end == null) return null;
  return (begin, end < begin ? begin : end);
}

List<String> _splitLines(String source) => source
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    // A UTF-8 BOM survives decoding as U+FEFF and would break the first block.
    .replaceFirst(RegExp(r'^﻿'), '')
    .split('\n');
