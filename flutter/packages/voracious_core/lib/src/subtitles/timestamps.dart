/// Timestamp parsing shared by the subtitle parsers.
library;

/// Matches the timestamp shapes all three supported formats use:
/// `H:MM:SS.cc`, `HH:MM:SS,mmm`, `MM:SS.mmm`. Hours are optional (WebVTT),
/// the decimal separator may be `.` or `,` (SRT files in the wild use both),
/// and the fraction may be 2 digits (ASS centiseconds) or 3 (milliseconds).
final RegExp timestampPattern =
    RegExp(r'(?:(\d+):)?(\d{1,2}):(\d{1,2})[.,](\d{1,3})');

/// Parses a subtitle timestamp, returning null if [text] is not one.
Duration? tryParseTimestamp(String text) {
  final match = timestampPattern.firstMatch(text.trim());
  if (match == null) return null;
  return _fromMatch(match);
}

/// Parses a subtitle timestamp, throwing [FormatException] if [text] is not
/// one.
Duration parseTimestamp(String text) {
  final result = tryParseTimestamp(text);
  if (result == null) {
    throw FormatException('not a subtitle timestamp', text);
  }
  return result;
}

Duration _fromMatch(Match match) {
  final hours = int.parse(match.group(1) ?? '0');
  final minutes = int.parse(match.group(2)!);
  final seconds = int.parse(match.group(3)!);
  final fraction = match.group(4)!;

  // "5" means 500ms and "05" means 50ms, so pad rather than parse directly.
  final millis = int.parse(fraction.padRight(3, '0'));

  return Duration(
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    milliseconds: millis,
  );
}

/// Formats [duration] as `HH:MM:SS,mmm` (SRT).
String formatSrtTimestamp(Duration duration) {
  final d = duration.isNegative ? Duration.zero : duration;
  final hours = d.inHours.toString().padLeft(2, '0');
  final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
  final millis = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
  return '$hours:$minutes:$seconds,$millis';
}

/// Formats [duration] as `HH:MM:SS.mmm` (WebVTT).
String formatVttTimestamp(Duration duration) =>
    formatSrtTimestamp(duration).replaceFirst(',', '.');
