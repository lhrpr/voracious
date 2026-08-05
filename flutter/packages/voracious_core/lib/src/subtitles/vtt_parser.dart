/// WebVTT (`.vtt`) parsing.
library;

import 'subtitle_cue.dart';
import 'subtitle_text.dart';
import 'timestamps.dart';

/// Parses WebVTT [source] into cues.
///
/// Header, `NOTE`, `STYLE` and `REGION` blocks are skipped; cue settings after
/// the end timestamp (`align:start position:0%`) are ignored, since positioning
/// is mpv's business rather than ours. Voice spans (`<v Narrator>`) and inline
/// timing tags are stripped by [cleanSubtitleText].
List<SubtitleCue> parseVtt(String source) {
  final cues = <SubtitleCue>[];

  final normalised = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceFirst(RegExp(r'^﻿'), '');

  for (final block in normalised.split(RegExp(r'\n[ \t]*\n'))) {
    final lines = block.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) continue;

    final first = lines.first.trimLeft();
    if (first.startsWith('WEBVTT') ||
        first.startsWith('NOTE') ||
        first.startsWith('STYLE') ||
        first.startsWith('REGION')) {
      continue;
    }

    // The block may open with a cue identifier line before the timing line.
    final timingIndex = lines.indexWhere((l) => l.contains('-->'));
    if (timingIndex < 0) continue;

    final timing = _parseTimingLine(lines[timingIndex]);
    if (timing == null) continue;

    final text = cleanSubtitleText(
      lines.sublist(timingIndex + 1).join('\n'),
      // `{` is not markup in WebVTT, and CSS-ish payloads do not reach here.
      stripOverrideBlocks: false,
    );
    if (text.isEmpty) continue;

    cues.add(SubtitleCue(begin: timing.$1, end: timing.$2, text: text));
  }

  return cues;
}

(Duration, Duration)? _parseTimingLine(String line) {
  final arrow = line.indexOf('-->');
  if (arrow < 0) return null;
  final begin = tryParseTimestamp(line.substring(0, arrow));
  final end = tryParseTimestamp(line.substring(arrow + 3));
  if (begin == null || end == null) return null;
  return (begin, end < begin ? begin : end);
}
