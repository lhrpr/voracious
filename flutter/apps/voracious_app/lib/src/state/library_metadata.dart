/// Matches the selected collection's titles to online metadata, in the
/// background after each scan.
///
/// The matching rules and cache live in `voracious_core`'s
/// [MetadataService]; this holds the results for the screen and decides when
/// to ask. Cached answers are shown straight away, then anything stale is
/// looked up one title at a time, so artwork appears progressively and a
/// first scan of a large library stays under the services' rate limits.
library;

import 'package:flutter/foundation.dart';
import 'package:voracious_core/voracious_core.dart';
import 'package:voracious_core/voracious_core_io.dart';

class LibraryMetadata extends ChangeNotifier {
  LibraryMetadata({required this.cache, this.artwork});

  /// Where matches are kept.
  final KeyValueStore cache;

  /// Posters and stills on disk. Null in tests, where images are not loaded.
  final IoArtworkCache? artwork;

  final IoMetadataTransport _transport = IoMetadataTransport();

  MetadataSettings _settings = const MetadataSettings();
  MetadataSettings get settings => _settings;

  late MetadataService _service = _serviceFor(_settings);

  MediaCollectionIndex _index = MediaCollectionIndex.empty;

  /// Each title's lookup, computed once per scan.
  Map<MediaTitle, MetadataQuery> _queries = const {};

  /// Results by [MetadataQuery.key]; absent means not looked up yet, null
  /// means no match.
  final Map<String, TitleMetadata?> _results = {};

  /// Keys whose match was chosen by hand.
  final Set<String> _manual = {};

  /// Bumped on every new scan or settings change, so a matching pass that has
  /// been overtaken stops instead of writing stale results.
  int _generation = 0;

  bool _matching = false;
  bool get isMatching => _matching;

  int _done = 0;
  int _total = 0;

  /// "3 of 12" while matching.
  (int, int) get progress => (_done, _total);

  String? _error;

  /// Why the last pass could not finish, e.g. a refused TMDB key.
  String? get error => _error;

  bool _disposed = false;

  MetadataService _serviceFor(MetadataSettings settings) => MetadataService(
        cache: cache,
        providers: settings.providers(_transport),
        signature: settings.signature,
      );

  /// Applies changed settings, looking everything up again if they affect
  /// what a lookup returns.
  Future<void> updateSettings(MetadataSettings settings) async {
    final changed = settings.signature != _settings.signature ||
        settings.enabled != _settings.enabled;
    _settings = settings;
    _service = _serviceFor(settings);
    if (changed) await _matchAll();
  }

  /// Shows cached matches for a freshly scanned [index], then refreshes
  /// whatever is missing or stale.
  Future<void> attach(MediaCollectionIndex index) async {
    _index = index;
    _queries = {
      for (final title in index.titles)
        if (MetadataQuery.forTitle(title, index) case final query?)
          title: query,
    };
    _error = null;
    await _matchAll();
  }

  Future<void> _matchAll() async {
    final generation = ++_generation;
    final service = _service;

    if (!_settings.enabled) {
      _results.clear();
      _manual.clear();
      _matching = false;
      _notify();
      return;
    }

    // Everything cached goes on screen before anything touches the network.
    final queries = _queries.values.toSet().toList();
    for (final query in queries) {
      final cached = await service.cached(query);
      if (generation != _generation) return;
      if (cached != null) _results[query.key] = cached.metadata;
      if (cached?.isManual ?? false) {
        _manual.add(query.key);
      } else {
        _manual.remove(query.key);
      }
    }

    _matching = true;
    _done = 0;
    _total = queries.length;
    _notify();

    for (final query in queries) {
      if (generation != _generation || _disposed) return;
      try {
        final result = await service.match(
          query,
          episodes: _episodesOnDisk(query),
        );
        if (generation != _generation) return;
        _results[query.key] = result;
      } on MetadataException catch (e) {
        if (generation != _generation) return;
        _error = e.message;
        // A refused key fails every lookup the same way; stop asking.
        if (e.isAuthFailure) break;
      }
      _done++;
      _notify();
    }

    if (generation != _generation) return;
    _matching = false;
    _notify();
  }

  /// The season/episode numbers on disk for every title sharing [query].
  List<(int?, int?)> _episodesOnDisk(MetadataQuery query) => [
        for (final MapEntry(key: title, value: q) in _queries.entries)
          if (q == query) ..._episodeNumbers(title),
      ];

  Iterable<(int?, int?)> _episodeNumbers(MediaTitle title) sync* {
    if (title.isSeries) {
      for (final episode in title.episodes) {
        yield (episode.season, episode.episode);
      }
    } else if (episodeNumberingOf(title) case final numbering?) {
      yield (numbering.season, numbering.episode);
    }
  }

  /// For a lone file named as an episode (`Mad.Men.S03E07.mkv`), its
  /// numbering; null for a film.
  EpisodeNumbering? episodeNumberingOf(MediaTitle title) {
    if (title.isSeries) return null;
    if (_queries[title]?.kind != MetadataKind.series) return null;
    final video = _index.videoById(title.videoId!);
    return video == null ? null : parseEpisodeNumbering(video.name);
  }

  MetadataQuery? queryFor(MediaTitle title) => _queries[title];

  /// The match for [title], or null when there is none (yet).
  TitleMetadata? metadataFor(MediaTitle title) {
    final query = _queries[title];
    return query == null ? null : _results[query.key];
  }

  /// Whether [title]'s match was picked by hand.
  bool isManual(MediaTitle title) =>
      _manual.contains(_queries[title]?.key);

  /// The listed episode for one of [title]'s episodes.
  EpisodeMetadata? episodeFor(MediaTitle title, SeriesEpisode episode) =>
      metadataFor(title)?.episode(episode.season, episode.episode);

  /// For a lone episode file, its listed episode.
  EpisodeMetadata? standaloneEpisodeFor(MediaTitle title) {
    final numbering = episodeNumberingOf(title);
    if (numbering == null) return null;
    return metadataFor(title)?.episode(numbering.season, numbering.episode);
  }

  /// Sources "Fix match" can search for [kind].
  List<MetadataSource> sourcesFor(MetadataKind kind) =>
      _service.sourcesFor(kind);

  Future<List<MetadataCandidate>> search(
    String text,
    MetadataKind kind,
    MetadataSource source,
  ) =>
      _service.search(text, kind, source);

  /// Matches [title] to [candidate] by hand.
  Future<void> choose(MediaTitle title, MetadataCandidate candidate) async {
    final query = _queries[title];
    if (query == null) return;
    final result = await _service.choose(query, candidate);
    _results[query.key] = result;
    _manual.add(query.key);
    _notify();
  }

  /// Marks [title] as having no match.
  Future<void> chooseNone(MediaTitle title) async {
    final query = _queries[title];
    if (query == null) return;
    await _service.chooseNone(query);
    _results[query.key] = null;
    _manual.add(query.key);
    _notify();
  }

  /// Looks [title] up again now, ignoring the cache. A match chosen by hand
  /// is kept (and re-fetched) unless [resetChoice], which goes back to
  /// automatic matching.
  Future<void> refresh(MediaTitle title, {bool resetChoice = false}) async {
    final query = _queries[title];
    if (query == null) return;
    if (resetChoice) {
      await _service.reset(query);
      _manual.remove(query.key);
    }
    try {
      _results[query.key] = await _service.match(
        query,
        episodes: _episodesOnDisk(query),
        force: true,
      );
      _error = null;
    } on MetadataException catch (e) {
      _error = e.message;
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _transport.close();
    artwork?.close();
    super.dispose();
  }
}
