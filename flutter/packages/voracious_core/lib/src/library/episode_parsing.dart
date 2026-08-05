/// Pulls season and episode numbers out of file names.
///
/// The naming conventions Kodi and Plex users follow are loose, and anime
/// releases follow different ones again. Getting this right is what decides
/// whether a series shows up as one title with 24 episodes or as 24 unrelated
/// titles, so it is worth more than the two regular expressions the Electron
/// app used.
library;

import 'package:meta/meta.dart';

/// Season/episode information recovered from a file name.
@immutable
class EpisodeNumbering {
  const EpisodeNumbering({
    this.season,
    required this.episode,
    this.title,
  });

  /// Season number, or null for a flat numbering scheme (most anime).
  final int? season;

  /// Episode number.
  final int episode;

  /// Episode title, when the name carries one after the number.
  final String? title;

  @override
  bool operator ==(Object other) =>
      other is EpisodeNumbering &&
      other.season == season &&
      other.episode == episode &&
      other.title == title;

  @override
  int get hashCode => Object.hash(season, episode, title);

  @override
  String toString() =>
      'EpisodeNumbering(s${season ?? '-'}e$episode${title != null ? ' "$title"' : ''})';
}

/// Patterns tried in order; the first match wins, so the most specific — the
/// ones that name a season explicitly — come first.
final List<RegExp> _seasonEpisodePatterns = [
  // S01E02, s1e2, S01.E02, S01 E02
  RegExp(r'\bs(?:eason)?\s*(\d{1,2})[\s._-]*e(?:p(?:isode)?)?\s*(\d{1,3})\b',
      caseSensitive: false),
  // 1x02
  RegExp(r'\b(\d{1,2})x(\d{2,3})\b', caseSensitive: false),
  // Season 1 Episode 2
  RegExp(r'\bseason\s*(\d{1,2}).{0,10}?episode\s*(\d{1,3})\b',
      caseSensitive: false),
];

final List<RegExp> _episodeOnlyPatterns = [
  // E02, EP02, Episode 2
  RegExp(r'\be(?:p(?:isode)?)?\s*(\d{1,3})\b', caseSensitive: false),
  // "Show Name - 05" and "Show Name - 05 - Title", the anime convention.
  RegExp(r'\s-\s*(\d{1,3})(?:\s*(?:-|$|\[|\())'),
  // "[05]" or "(05)"
  RegExp(r'[\[(](\d{1,3})[\])]'),
  // "Show Name 05v2"
  RegExp(r'\s(\d{1,3})v\d\b', caseSensitive: false),
];

/// Media extensions stripped before parsing, so callers may pass either a file
/// name or a bare title.
const Set<String> _strippableExtensions = {
  'mkv', 'mp4', 'm4v', 'avi', 'mov', 'webm', 'ts', 'm2ts', 'mts', 'wmv', //
  'flv', 'ogv', 'ogm', 'mpg', 'mpeg', 'divx', 'rmvb', 'vob', '3gp',
  'srt', 'vtt', 'ass', 'ssa',
};

String _withoutExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return name;
  return _strippableExtensions.contains(name.substring(dot + 1).toLowerCase())
      ? name.substring(0, dot)
      : name;
}

/// Parses season/episode numbering out of [name], returning null when it does
/// not look like an episode.
///
/// [name] may be a file name or a bare title; a media extension is stripped
/// first, since otherwise `.mkv` would be read as the episode title.
EpisodeNumbering? parseEpisodeNumbering(String rawName) {
  final name = _withoutExtension(rawName);

  for (final pattern in _seasonEpisodePatterns) {
    final match = pattern.firstMatch(name);
    if (match == null) continue;
    return EpisodeNumbering(
      season: int.parse(match.group(1)!),
      episode: int.parse(match.group(2)!),
      title: _titleAfter(name, match.end),
    );
  }

  for (final pattern in _episodeOnlyPatterns) {
    final match = pattern.firstMatch(name);
    if (match == null) continue;
    final episode = int.parse(match.group(1)!);
    // A four-digit-looking number is a year or a resolution, not an episode;
    // the patterns already cap at three digits, but guard the common 1080/720
    // and 2019-style cases that slip through as three digits plus context.
    if (_looksLikeMetadata(name, match)) continue;
    return EpisodeNumbering(
      episode: episode,
      title: _titleAfter(name, match.end),
    );
  }

  return null;
}

/// True when the matched number is part of a resolution, a year, or a codec
/// tag rather than an episode number.
bool _looksLikeMetadata(String name, Match match) {
  final before = name.substring(0, match.start).toLowerCase();
  final after = name.substring(match.end).toLowerCase();
  if (after.startsWith('p') || after.startsWith('i')) return true; // 1080p
  if (before.endsWith('x') || before.endsWith('h')) return true; // x264, h264
  if (RegExp(r'(19|20)\d{2}').hasMatch(match.group(0)!)) return true;
  return false;
}

/// Everything after the episode number, tidied into a title, or null.
String? _titleAfter(String name, int index) {
  if (index >= name.length) return null;
  var rest = name.substring(index);
  // Strip the separator the number was followed by.
  rest = rest.replaceFirst(RegExp(r'^[\s._-]+'), '');
  // Drop release metadata in brackets.
  rest = rest.replaceAll(RegExp(r'[\[(][^\])]*[\])]'), ' ');
  rest = rest.replaceAll(RegExp(r'[._]'), ' ').trim();
  rest = rest.replaceAll(RegExp(r'\s{2,}'), ' ');
  return rest.isEmpty ? null : rest;
}

/// Recognises a season directory name: `Season 1`, `Season01`, `S2`,
/// `Specials`.
///
/// Returns the season number, `0` for specials, or null when the directory is
/// not a season.
int? parseSeasonDirectory(String directoryName) {
  final name = directoryName.trim();
  if (RegExp(r'^specials?$', caseSensitive: false).hasMatch(name)) return 0;
  final match = RegExp(r'^s(?:eason)?[\s._-]*(\d{1,2})$', caseSensitive: false)
      .firstMatch(name);
  if (match == null) return null;
  return int.parse(match.group(1)!);
}

/// Cleans a directory or file name into something worth showing as a title.
///
/// Strips release-group brackets, resolution and codec tags, and turns
/// separators into spaces — `[Group] Show Name (2019) [1080p][x265]` becomes
/// `Show Name`.
String prettifyTitle(String rawName) {
  var name = _withoutExtension(rawName);

  // Leading release group tag.
  name = name.replaceFirst(RegExp(r'^\s*[\[(][^\])]*[\])]\s*'), '');
  // Any remaining bracketed metadata.
  name = name.replaceAll(RegExp(r'[\[(][^\])]*[\])]'), ' ');
  name = name.replaceAll(RegExp(r'[._]+'), ' ');

  // Cut at the first release-metadata token; everything after it is noise.
  final metadata = RegExp(
    r'\b(?:\d{3,4}[pi]|x26[45]|h\.?26[45]|hevc|bluray|blu-ray|web-?dl|webrip|'
    r'hdtv|dvdrip|bdrip|remux|aac|ac3|dts|flac|10bit|8bit|hdr|sdr|multi|dual)\b',
    caseSensitive: false,
  );
  final cut = metadata.firstMatch(name);
  if (cut != null && cut.start > 0) {
    var end = cut.start;
    // A year immediately before the metadata is release information too. On
    // its own it is not: `Blade Runner 2049` is a title, `Movie 2019 1080p`
    // is a title plus a year.
    final year =
        RegExp(r'\b(?:19|20)\d{2}\s*$').firstMatch(name.substring(0, end));
    if (year != null && year.start > 0) end = year.start;
    name = name.substring(0, end);
  }

  name = name.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  name = name.replaceAll(RegExp(r'[\s\-]+$'), '');
  return name.isEmpty ? rawName.trim() : name;
}
