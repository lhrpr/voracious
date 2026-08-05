/// Subtitle format identification and parser dispatch.
library;

import 'ass_parser.dart';
import 'srt_parser.dart';
import 'subtitle_cue.dart';
import 'vtt_parser.dart';

/// Text subtitle formats Voracious can read.
///
/// Only text formats appear here. Bitmap subtitles (VobSub, PGS) carry no text
/// to tokenise or look up, so they are left to mpv to render and are never
/// turned into study tracks.
enum SubtitleFormat {
  srt(['srt'], 'SubRip'),
  vtt(['vtt', 'webvtt'], 'WebVTT'),
  ass(['ass', 'ssa'], 'Advanced SubStation Alpha');

  const SubtitleFormat(this.extensions, this.displayName);

  /// Lower-case file extensions, without the leading dot.
  final List<String> extensions;
  final String displayName;

  /// Every extension recognised as a text subtitle track.
  static Set<String> get allExtensions =>
      {for (final f in SubtitleFormat.values) ...f.extensions};

  /// Identifies a format from a file name or extension, or null if unknown.
  static SubtitleFormat? fromPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return null;
    final extension = path.substring(dot + 1).toLowerCase();
    for (final format in SubtitleFormat.values) {
      if (format.extensions.contains(extension)) return format;
    }
    return null;
  }

  /// Identifies a format by sniffing [source], for cases where the extension
  /// is missing or lies (a `.txt` dump of an SRT is common).
  static SubtitleFormat? sniff(String source) {
    final head = source.length > 4096 ? source.substring(0, 4096) : source;
    if (head.contains('[Script Info]') ||
        head.contains('[Events]') ||
        head.contains('[V4+ Styles]') ||
        head.contains('[V4 Styles]')) {
      return SubtitleFormat.ass;
    }
    if (RegExp(r'^\s*﻿?WEBVTT').hasMatch(head)) return SubtitleFormat.vtt;
    if (head.contains('-->')) {
      // WebVTT uses `.` for the fraction, SubRip uses `,`; either may appear in
      // a sloppy file, so prefer SubRip only when a comma-form timing is found.
      if (RegExp(r'\d{2}:\d{2}:\d{2},\d{3}\s*-->').hasMatch(head)) {
        return SubtitleFormat.srt;
      }
      return SubtitleFormat.vtt;
    }
    return null;
  }
}

/// Parses [source] as [format].
List<SubtitleCue> parseSubtitles(
  String source,
  SubtitleFormat format, {
  Set<String> excludeAssStyles = const {},
}) {
  switch (format) {
    case SubtitleFormat.srt:
      return parseSrt(source);
    case SubtitleFormat.vtt:
      return parseVtt(source);
    case SubtitleFormat.ass:
      return parseAss(source, excludeStyles: excludeAssStyles);
  }
}

/// Parses [source] after working out its format from [path], falling back to
/// sniffing the content.
///
/// Throws [UnsupportedSubtitleFormatException] when neither identifies a
/// format.
List<SubtitleCue> parseSubtitlesForPath(
  String source,
  String path, {
  Set<String> excludeAssStyles = const {},
}) {
  final format = SubtitleFormat.fromPath(path) ?? SubtitleFormat.sniff(source);
  if (format == null) {
    throw UnsupportedSubtitleFormatException(path);
  }
  return parseSubtitles(source, format, excludeAssStyles: excludeAssStyles);
}

class UnsupportedSubtitleFormatException implements Exception {
  const UnsupportedSubtitleFormatException(this.path);

  final String path;

  @override
  String toString() =>
      'UnsupportedSubtitleFormatException: cannot determine subtitle format '
      'of "$path"';
}
