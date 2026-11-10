/// Turning a scanned title into a lookup, and deciding which search result is
/// the same title.
library;

import 'package:meta/meta.dart';

import '../library/episode_parsing.dart';
import '../library/media_library.dart';
import 'metadata_models.dart';

/// What to look a scanned title up as.
@immutable
class MetadataQuery {
  const MetadataQuery({
    required this.kind,
    required this.name,
    this.year,
    this.country,
  });

  /// The lookup for [title], or null when there is nothing to look up.
  ///
  /// A folder of episodes is a series. A lone file is a film, unless its name
  /// carries season-and-episode numbering (`Mad.Men.S03E07.mkv` loose in the
  /// collection root), in which case it is an episode of the series named in
  /// front of the numbering.
  static MetadataQuery? forTitle(MediaTitle title, MediaCollectionIndex index) {
    final country = parseCountryTag(title.sourceName ?? title.name);
    if (title.isSeries) {
      return _query(MetadataKind.series, title.name, title.year, country);
    }
    final video = index.videoById(title.videoId!);
    final seriesName =
        video == null ? null : seriesNameFromEpisodeFile(video.name);
    if (seriesName != null) {
      return _query(MetadataKind.series, seriesName,
          parseReleaseYear(video!.name), parseCountryTag(seriesName));
    }
    return _query(MetadataKind.movie, title.name, title.year, country);
  }

  static MetadataQuery? _query(
    MetadataKind kind,
    String name,
    int? year,
    String? country,
  ) {
    var cleaned = name.trim();
    // `Doctor Who 2005` keeps its year in the display name when no release
    // metadata followed it; it is not part of what to search for.
    if (year != null) {
      cleaned = cleaned.replaceFirst(RegExp('\\s*\\(?$year\\)?\$'), '');
    }
    // Nor is a country tag: no service calls the show `The Office US`.
    if (country != null) {
      cleaned = cleaned.replaceFirst(_trailingCountry, '');
    }
    if (normalizeTitle(cleaned).isEmpty) return null;
    return MetadataQuery(kind: kind, name: cleaned, year: year, country: country);
  }

  final MetadataKind kind;
  final String name;
  final int? year;

  /// ISO 3166-1 alpha-2, from a tag like `(US)` in the name.
  final String? country;

  /// Identifies the lookup in the cache. Two folders that clean up to the same
  /// name, year and country share a match, which is what they should do.
  String get key => '${kind.name}/${normalizeTitle(name)}/${year ?? ''}'
      '${country == null ? '' : '/$country'}';

  @override
  bool operator ==(Object other) =>
      other is MetadataQuery && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'MetadataQuery($key)';
}

/// Country tags release names use, by the code services report.
const Map<String, String> _countryTags = {
  'US': 'US', 'UK': 'GB', 'GB': 'GB', 'AU': 'AU', 'NZ': 'NZ', 'CA': 'CA', //
  'IE': 'IE',
};

final RegExp _trailingCountry =
    RegExp(r'[\s._]*[(\[]?\b(?:US|UK|GB|AU|NZ|CA|IE)\b[)\]]?\s*$');

/// The country a name is tagged with — `The Office (US)`, `Shameless.UK`,
/// `The Office US 2005` — as an ISO code, or null.
///
/// Only an upper-case tag after the title counts, so "us" in `Between Us`
/// is not read as one.
String? parseCountryTag(String rawName) {
  final spaced = rawName.replaceAll(RegExp(r'[._]+'), ' ');
  final match = RegExp(r'\S[\s(\[]+(US|UK|GB|AU|NZ|CA|IE)(?=[)\]]|\s|$)')
      .firstMatch(spaced);
  return match == null ? null : _countryTags[match.group(1)!];
}

/// Lowercase letters and digits separated by single spaces, `&` read as
/// `and`, apostrophes dropped and a leading "the" removed — so `The Office`,
/// `Office, The` and `office` compare equal, and `Grey's Anatomy` matches
/// `Greys Anatomy`.
String normalizeTitle(String title) {
  var text = title.toLowerCase().replaceAll('&', ' and ');
  text = text.replaceAll(RegExp(r"['’`]"), '');
  text = text.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();
  text = text.replaceFirst(RegExp(r'^the\s+'), '');
  text = text.replaceFirst(RegExp(r'\s+the$'), '');
  return text;
}

/// How alike a search result is to the query, from about -0.3 to 1.15.
///
/// The name decides it: an exact match after normalising scores 1, otherwise
/// the overlap of their words, discounted. The year then nudges — it is what
/// separates a remake from the original, but release years in folder names are
/// often a year off from a series' premiere.
double matchScore(MetadataQuery query, MetadataCandidate candidate) {
  final a = normalizeTitle(query.name);
  final b = normalizeTitle(candidate.name);
  if (a.isEmpty || b.isEmpty) return 0;

  var score = a == b ? 1.0 : 0.9 * _diceOverWords(a, b);

  final wanted = query.year;
  final found = candidate.year;
  if (wanted != null && found != null) {
    final difference = (wanted - found).abs();
    score += switch (difference) { 0 => 0.15, 1 => 0.05, _ => -0.3 };
  }

  final country = query.country;
  if (country != null && candidate.countries.isNotEmpty) {
    score += candidate.countries.contains(country) ? 0.15 : -0.3;
  }
  return score;
}

double _diceOverWords(String a, String b) {
  final wordsA = a.split(' ').toSet();
  final wordsB = b.split(' ').toSet();
  final shared = wordsA.intersection(wordsB).length;
  return 2 * shared / (wordsA.length + wordsB.length);
}

/// Below this, a result is not trusted enough to apply without asking.
const double minimumMatchScore = 0.75;

/// The result that is plainly the same title, or null.
///
/// Ties go to the earlier result, since both services order by relevance and
/// popularity — the better-known of two same-named series is the likelier.
MetadataCandidate? bestCandidate(
  MetadataQuery query,
  List<MetadataCandidate> candidates,
) {
  MetadataCandidate? best;
  var bestScore = minimumMatchScore - 1e-9;
  for (final candidate in candidates) {
    if (candidate.kind != query.kind) continue;
    final score = matchScore(query, candidate);
    if (score > bestScore) {
      best = candidate;
      bestScore = score;
    }
  }
  return best;
}
