/// Reads language and variant information out of subtitle file names.
///
/// Almost every organised media collection encodes the subtitle language in the
/// file name — `Movie.en.srt`, `Show.S01E02.jpn.ass`, `Film.pt-BR.forced.srt`.
/// That tag is far more reliable than statistical detection, and it is free, so
/// it is tried first and detection only fills in the gaps.
library;

import 'package:meta/meta.dart';

import 'language_table.dart';

/// What a subtitle file name says about its track.
@immutable
class SubtitleLanguageTag {
  const SubtitleLanguageTag({
    required this.baseName,
    this.iso6393,
    this.regionCode,
    this.scriptCode,
    this.forced = false,
    this.hearingImpaired = false,
    this.label,
  });

  /// The file name with the subtitle extension and every recognised tag
  /// removed. This is what gets matched against video file names.
  final String baseName;

  /// Three-letter language code, or null when the name carries none.
  final String? iso6393;

  /// Upper-case region subtag, e.g. `BR` in `pt-BR`.
  final String? regionCode;

  /// Script subtag, e.g. `Hans` in `zh-Hans`.
  final String? scriptCode;

  /// A forced track: only the subtitles for foreign dialogue and signs. Useless
  /// as a study track, since it covers a fraction of the dialogue.
  final bool forced;

  /// An SDH / CC track, which includes sound descriptions.
  final bool hearingImpaired;

  /// Any leftover descriptive tag, e.g. the release group's name.
  final String? label;

  /// Language plus script/region, as a BCP 47-ish string for display.
  String? get displayTag {
    final language = iso6393;
    if (language == null) return null;
    final short = toIso6391(language) ?? language;
    return [
      short,
      if (scriptCode != null) scriptCode,
      if (regionCode != null) regionCode
    ].join('-');
  }

  @override
  String toString() => 'SubtitleLanguageTag($baseName, ${iso6393 ?? '?'}'
      '${forced ? ', forced' : ''}${hearingImpaired ? ', sdh' : ''})';
}

const Set<String> _forcedMarkers = {'forced', 'foreign'};
const Set<String> _hearingImpairedMarkers = {'sdh', 'cc', 'hi', 'hoh'};

/// Descriptive tags worth recording. Kept to a closed list: anything else in
/// that position is part of the title, and an open-ended "probably a label"
/// rule would eat `S01E01` out of `Show.S01E01.jpn.srt`.
const Set<String> _labelMarkers = {
  'commentary',
  'director',
  'song',
  'songs',
  'signs',
  'lyrics',
  'karaoke',
  'full',
  'dialogue',
};

/// Tags that name a language in a way ISO 639 does not, seen in the wild.
const Map<String, String> _extraLanguageAliases = {
  'jp': 'jpn',
  'ja': 'jpn',
  'jap': 'jpn',
  'japanese': 'jpn',
  'english': 'eng',
  'eng': 'eng',
  'chs': 'zho',
  'cht': 'zho',
  'chi': 'zho',
  'zh': 'zho',
  'chinese': 'zho',
  'kor': 'kor',
  'korean': 'kor',
  'spanish': 'spa',
  'french': 'fra',
  'fre': 'fra',
  'german': 'deu',
  'ger': 'deu',
  'italian': 'ita',
  'portuguese': 'por',
  'russian': 'rus',
  'dutch': 'nld',
  'dut': 'nld',
  'swedish': 'swe',
  'polish': 'pol',
  'czech': 'ces',
  'cze': 'ces',
  'arabic': 'ara',
  'thai': 'tha',
  'turkish': 'tur',
  'vietnamese': 'vie',
  'indonesian': 'ind',
};

const Set<String> _scriptCodes = {
  'hans',
  'hant',
  'latn',
  'cyrl',
  'arab',
  'hebr',
  'jpan',
  'kore',
  'hani',
};

/// Parses the tags in [fileName] (with or without its extension).
///
/// Tags are the dot-separated segments after the title. Parsing walks from the
/// right and stops at the first segment it does not recognise, which is what
/// keeps a title like `Blade.Runner.2049` from having `2049` eaten.
SubtitleLanguageTag parseSubtitleLanguageTag(String fileName) {
  var name = fileName;

  // Drop the subtitle extension if present.
  final lastDot = name.lastIndexOf('.');
  if (lastDot > 0) {
    final extension = name.substring(lastDot + 1).toLowerCase();
    if (const {'srt', 'vtt', 'ass', 'ssa', 'webvtt'}.contains(extension)) {
      name = name.substring(0, lastDot);
    }
  }

  final segments = name.split('.');
  String? iso6393;
  String? region;
  String? script;
  var forced = false;
  var hearingImpaired = false;
  String? label;

  var lastConsumed = segments.length;
  for (var i = segments.length - 1; i >= 1; i--) {
    final segment = segments[i].trim();
    if (segment.isEmpty) {
      lastConsumed = i;
      continue;
    }
    final lower = segment.toLowerCase();

    if (_forcedMarkers.contains(lower)) {
      forced = true;
      lastConsumed = i;
      continue;
    }
    if (_hearingImpairedMarkers.contains(lower)) {
      hearingImpaired = true;
      lastConsumed = i;
      continue;
    }

    final parsed = _parseLanguageSegment(lower);
    if (parsed != null && iso6393 == null) {
      iso6393 = parsed.$1;
      script = parsed.$2;
      region = parsed.$3;
      lastConsumed = i;
      continue;
    }

    if (_labelMarkers.contains(lower) && label == null) {
      label = segment;
      lastConsumed = i;
      continue;
    }

    // Anything else is part of the title, so the tag run ends here.
    break;
  }

  return SubtitleLanguageTag(
    baseName: segments.sublist(0, lastConsumed).join('.'),
    iso6393: iso6393,
    regionCode: region,
    scriptCode: script,
    forced: forced,
    hearingImpaired: hearingImpaired,
    label: label,
  );
}

/// Parses `pt-BR`, `zh-Hans`, `jpn` or `ja` into (language, script, region).
(String, String?, String?)? _parseLanguageSegment(String segment) {
  final parts = segment.split(RegExp('[-_]'));
  final languagePart = parts.first;

  final language =
      _extraLanguageAliases[languagePart] ?? toIso6393(languagePart);
  if (language == null) return null;
  // A bare two/three letter word could be part of a title; require it to be a
  // real code, which `toIso6393` already guarantees.

  String? script;
  String? region;
  for (final part in parts.skip(1)) {
    if (part.length == 4 && _scriptCodes.contains(part)) {
      script = part[0].toUpperCase() + part.substring(1);
    } else if (part.length == 2) {
      region = part.toUpperCase();
    }
  }

  return (language, script, region);
}
