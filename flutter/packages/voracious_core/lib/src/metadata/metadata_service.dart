/// Matches titles to metadata and remembers the answer.
///
/// A library is rescanned every time it is opened, so lookups have to come
/// from a cache almost always: a hit is kept for a month, a miss for a few
/// days, and either is looked up again early only when it is plainly out of
/// date (an episode on disk the listing does not have yet, or the settings it
/// was made with have changed).
///
/// A choice made by hand in "Fix match" is stored apart from the cache, so it
/// survives refreshes and is never second-guessed by the automatic matcher.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../settings/key_value_store.dart';
import 'metadata_http.dart';
import 'metadata_models.dart';
import 'metadata_provider.dart';
import 'title_matching.dart';

/// A cached lookup.
@immutable
class MetadataMatch {
  const MetadataMatch({
    required this.metadata,
    required this.checkedAt,
    required this.signature,
    this.isManual = false,
  });

  /// Null when the lookup found nothing, or the user chose "no match".
  final TitleMetadata? metadata;
  final DateTime checkedAt;

  /// The settings signature it was looked up with.
  final String signature;

  /// Chosen by hand rather than by the automatic matcher.
  final bool isManual;
}

class MetadataService {
  MetadataService({
    required this.cache,
    required this.providers,
    required this.signature,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Where matches are kept. A separate store from the profile is best: the
  /// listings are large next to everything else, and change rarely.
  final KeyValueStore cache;

  /// Services to try, most preferred first.
  final List<MetadataProvider> providers;

  /// Identifies the settings these providers were made from; see
  /// `MetadataSettings.signature`.
  final String signature;

  final DateTime Function() _clock;

  static const String matchPrefix = 'metadata/match/';
  static const String choicePrefix = 'metadata/choice/';

  static const Duration hitLifetime = Duration(days: 30);
  static const Duration missLifetime = Duration(days: 3);

  /// How soon a listing missing an episode on disk may be looked up again.
  /// Without a floor, an episode the service will never list would cause a
  /// request on every scan.
  static const Duration missingEpisodeRetry = Duration(days: 1);

  /// The cached match for [query], without going to the network.
  Future<MetadataMatch?> cached(MetadataQuery query) async {
    final choice = await _readChoice(query);
    if (choice case _NoMatchChoice()) {
      return MetadataMatch(
        metadata: null,
        checkedAt: _clock(),
        signature: signature,
        isManual: true,
      );
    }
    return _readMatch(query, isManual: choice != null);
  }

  /// Looks [query] up, from the cache when the cached answer is still good.
  ///
  /// [episodes] are the season/episode numbers on disk; a listing missing one
  /// of them is refreshed. A failed lookup returns the stale cached answer
  /// when there is one, and throws [MetadataException] when there is not.
  Future<TitleMetadata?> match(
    MetadataQuery query, {
    Iterable<(int?, int?)> episodes = const [],
    bool force = false,
  }) async {
    final choice = await _readChoice(query);
    if (choice is _NoMatchChoice) return null;

    final cachedMatch = await _readMatch(query, isManual: choice != null);
    if (!force &&
        cachedMatch != null &&
        _isFresh(cachedMatch, episodes)) {
      return cachedMatch.metadata;
    }

    try {
      final TitleMetadata? metadata;
      if (choice case _ChosenTitle(:final source, :final id, :final kind)) {
        final provider = _provider(source);
        // The chosen service is unavailable (its key was removed): keep what
        // was fetched while it was.
        if (provider == null) return cachedMatch?.metadata;
        metadata = await provider.fetch(id, kind);
      } else {
        metadata = await _lookUp(query);
      }
      await _writeMatch(query, metadata);
      return metadata;
    } on MetadataException {
      if (cachedMatch != null) return cachedMatch.metadata;
      rethrow;
    }
  }

  /// Searches one service for "Fix match".
  Future<List<MetadataCandidate>> search(
    String text,
    MetadataKind kind,
    MetadataSource source,
  ) async {
    final provider = _provider(source);
    if (provider == null || !provider.supports(kind)) return const [];
    return provider.search(text, kind);
  }

  /// Sources that can look up [kind], in order of preference.
  List<MetadataSource> sourcesFor(MetadataKind kind) => [
        for (final provider in providers)
          if (provider.supports(kind)) provider.source,
      ];

  /// Matches [query] to [candidate] by hand.
  Future<TitleMetadata?> choose(
    MetadataQuery query,
    MetadataCandidate candidate,
  ) async {
    final provider = _provider(candidate.source);
    if (provider == null) {
      throw MetadataException('${candidate.source.label} is not set up');
    }
    final metadata = await provider.fetch(candidate.id, candidate.kind);
    await cache.set(
      _choiceKey(query),
      jsonEncode({
        'source': candidate.source.name,
        'id': candidate.id,
        'kind': candidate.kind.name,
      }),
    );
    await _writeMatch(query, metadata);
    return metadata;
  }

  /// Marks [query] as having no match, so it is never looked up.
  Future<void> chooseNone(MetadataQuery query) async {
    await cache.set(_choiceKey(query), jsonEncode({'none': true}));
    await cache.remove(_matchKey(query));
  }

  /// Forgets any choice and cached answer for [query], so the next lookup is
  /// automatic and fresh.
  Future<void> reset(MetadataQuery query) async {
    await cache.remove(_choiceKey(query));
    await cache.remove(_matchKey(query));
  }

  bool _isFresh(MetadataMatch match, Iterable<(int?, int?)> episodes) {
    if (match.signature != signature) return false;
    final age = _clock().difference(match.checkedAt);
    final metadata = match.metadata;
    if (metadata == null) return age < missLifetime;
    if (age >= hitLifetime) return false;
    final missing = episodes.any((e) =>
        e.$2 != null && metadata.episode(e.$1, e.$2) == null);
    return !missing || age < missingEpisodeRetry;
  }

  /// Asks each service in turn and fetches the first confident match.
  Future<TitleMetadata?> _lookUp(MetadataQuery query) async {
    MetadataException? failure;
    for (final provider in providers) {
      if (!provider.supports(query.kind)) continue;
      try {
        final results = await provider.search(query.name, query.kind);
        final best = bestCandidate(query, results);
        if (best == null) continue;
        final metadata = await provider.fetch(best.id, best.kind);
        if (metadata != null) return metadata;
      } on MetadataException catch (error) {
        // One service being down or refusing a key should not stop the next
        // from being asked.
        failure ??= error;
      }
    }
    // Nothing found anywhere, but only because a service failed: that is not
    // a miss worth caching.
    if (failure != null) throw failure;
    return null;
  }

  MetadataProvider? _provider(MetadataSource source) {
    for (final provider in providers) {
      if (provider.source == source) return provider;
    }
    return null;
  }

  static String _matchKey(MetadataQuery query) => '$matchPrefix${query.key}';
  static String _choiceKey(MetadataQuery query) => '$choicePrefix${query.key}';

  Future<MetadataMatch?> _readMatch(
    MetadataQuery query, {
    required bool isManual,
  }) async {
    final raw = await cache.get(_matchKey(query));
    if (raw == null) return null;
    try {
      final json = (jsonDecode(raw) as Map).cast<String, Object?>();
      final result = json['result'];
      return MetadataMatch(
        metadata: result is Map
            ? TitleMetadata.fromJson(result.cast<String, Object?>())
            : null,
        checkedAt: DateTime.fromMillisecondsSinceEpoch(
            (json['checkedAt']! as num).toInt()),
        signature: json['signature'] as String? ?? '',
        isManual: isManual,
      );
    } on Object {
      // A damaged entry is a cache miss, not an error.
      return null;
    }
  }

  Future<void> _writeMatch(MetadataQuery query, TitleMetadata? metadata) =>
      cache.set(
        _matchKey(query),
        jsonEncode({
          'checkedAt': _clock().millisecondsSinceEpoch,
          'signature': signature,
          'result': metadata?.toJson(),
        }),
      );

  Future<_Choice?> _readChoice(MetadataQuery query) async {
    final raw = await cache.get(_choiceKey(query));
    if (raw == null) return null;
    try {
      final json = (jsonDecode(raw) as Map).cast<String, Object?>();
      if (json['none'] == true) return const _NoMatchChoice();
      final source = MetadataSource.byName(json['source']);
      final kind = MetadataKind.byName(json['kind']);
      final id = json['id'];
      if (source == null || kind == null || id is! String) return null;
      return _ChosenTitle(source, id, kind);
    } on Object {
      return null;
    }
  }
}

sealed class _Choice {
  const _Choice();
}

class _NoMatchChoice extends _Choice {
  const _NoMatchChoice();
}

class _ChosenTitle extends _Choice {
  const _ChosenTitle(this.source, this.id, this.kind);

  final MetadataSource source;
  final String id;
  final MetadataKind kind;
}
