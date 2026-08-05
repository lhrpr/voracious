/// Advanced SubStation Alpha (`.ass`) and SubStation Alpha (`.ssa`) parsing.
library;

import 'subtitle_cue.dart';
import 'subtitle_text.dart';
import 'timestamps.dart';

/// Parses ASS/SSA [source] into cues.
///
/// Fields are located by name from the `Format:` line rather than by position,
/// which is what makes the same code work for SSA v4 (`Marked`) and ASS v4+
/// (`Layer`). Only `Dialogue:` events are returned — `Comment:` lines are
/// translator notes and typesetting scratch, never dialogue.
///
/// [excludeStyles] drops events whose style name matches (case-insensitively).
/// Anime releases put signs, credits and karaoke in separate styles, and those
/// are noise in a study track.
List<SubtitleCue> parseAss(
  String source, {
  Set<String> excludeStyles = const {},
}) {
  final lines = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceFirst(RegExp(r'^﻿'), '')
      .split('\n');

  final excluded = excludeStyles.map((s) => s.toLowerCase()).toSet();
  final cues = <SubtitleCue>[];

  var inEvents = false;
  List<String>? fields;

  for (final rawLine in lines) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('[')) {
      inEvents = line.toLowerCase().startsWith('[events]');
      fields = null;
      continue;
    }
    if (!inEvents) continue;

    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final descriptor = line.substring(0, colon).trim().toLowerCase();
    final payload = line.substring(colon + 1);

    if (descriptor == 'format') {
      fields = payload.split(',').map((f) => f.trim()).toList();
      continue;
    }
    if (descriptor != 'dialogue' || fields == null) continue;

    final cue = _parseDialogue(payload, fields, excluded);
    if (cue != null) cues.add(cue);
  }

  return cues;
}

SubtitleCue? _parseDialogue(
  String payload,
  List<String> fields,
  Set<String> excludedStyles,
) {
  final startIndex = _indexOfField(fields, 'start');
  final endIndex = _indexOfField(fields, 'end');
  final textIndex = _indexOfField(fields, 'text');
  if (startIndex < 0 || endIndex < 0 || textIndex < 0) return null;

  // Text is the last field by definition and may itself contain commas, so
  // split at most `fields.length - 1` times and let the remainder be the text.
  final values = _splitLimit(payload, ',', fields.length);
  if (values.length < fields.length) return null;

  final begin = tryParseTimestamp(values[startIndex]);
  final end = tryParseTimestamp(values[endIndex]);
  if (begin == null || end == null) return null;

  final styleIndex = _indexOfField(fields, 'style');
  final style = styleIndex >= 0 ? values[styleIndex].trim() : null;
  if (style != null && excludedStyles.contains(style.toLowerCase())) {
    return null;
  }

  final layerIndex = _indexOfField(fields, 'layer');
  final layer =
      layerIndex >= 0 ? int.tryParse(values[layerIndex].trim()) ?? 0 : 0;

  final text = cleanSubtitleText(values[textIndex]);
  if (text.isEmpty) return null;

  return SubtitleCue(
    begin: begin,
    end: end < begin ? begin : end,
    text: text,
    styleName: style,
    layer: layer,
  );
}

int _indexOfField(List<String> fields, String name) =>
    fields.indexWhere((f) => f.toLowerCase() == name);

/// Splits [text] on [separator] into at most [limit] parts; the final part
/// keeps any remaining separators.
List<String> _splitLimit(String text, String separator, int limit) {
  if (limit <= 1) return [text];
  final parts = <String>[];
  var start = 0;
  while (parts.length < limit - 1) {
    final index = text.indexOf(separator, start);
    if (index < 0) break;
    parts.add(text.substring(start, index));
    start = index + separator.length;
  }
  parts.add(text.substring(start));
  return parts;
}

/// Style names that anime and film releases conventionally use for material
/// that is not dialogue. Offered as a sensible default for [excludeStyles];
/// not applied automatically, because some releases put dialogue in `Sign`.
const Set<String> conventionalNonDialogueStyles = {
  'sign',
  'signs',
  'title',
  'titles',
  'credit',
  'credits',
  'op',
  'ed',
  'karaoke',
  'romaji',
  'staff',
};
