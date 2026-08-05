/// The model a scanned collection produces.
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../subtitles/subtitle_format.dart';

/// Container extensions treated as playable video.
///
/// mpv opens far more than this; the list exists to stop the scanner claiming
/// every stray file, not to limit playback.
const Set<String> videoFileExtensions = {
  'mkv', 'mp4', 'm4v', 'avi', 'mov', 'webm', 'ts', 'm2ts', 'mts', 'wmv', //
  'flv', 'ogv', 'ogm', 'mpg', 'mpeg', 'divx', 'rmvb', 'vob', '3gp',
};

/// Directory names that hold subtitles for the videos beside them.
const Set<String> subtitleDirectoryNames = {'subs', 'subtitles', 'sub'};

/// An external subtitle file attached to a video.
@immutable
class SubtitleFileRef {
  const SubtitleFileRef({
    required this.id,
    required this.path,
    required this.format,
    this.languageCode,
    this.label,
    this.forced = false,
    this.hearingImpaired = false,
  });

  /// Path relative to the collection root. Stable across scans, so it is what
  /// preferences and cached analysis are keyed on.
  final String id;

  /// Full path for reading.
  final String path;

  final SubtitleFormat format;

  /// ISO 639-3 code from the file name, or null if the name carried none. The
  /// track's real language is only known once it has been read and detected.
  final String? languageCode;

  /// Descriptive tag from the file name, if any.
  final String? label;

  final bool forced;
  final bool hearingImpaired;

  /// Forced and SDH tracks are poor study material — one covers a fraction of
  /// the dialogue, the other is padded with sound descriptions.
  bool get isGoodStudyTrack => !forced && !hearingImpaired;

  @override
  String toString() => 'SubtitleFileRef($id, ${languageCode ?? '?'})';
}

/// A playable video file with whatever subtitles were found beside it.
@immutable
class VideoEntry {
  const VideoEntry({
    required this.id,
    required this.name,
    required this.path,
    required this.subtitleFiles,
    this.sizeInBytes,
  });

  /// Path relative to the collection root; the video's stable identity.
  final String id;

  /// File name without extension.
  final String name;

  /// Full path, for handing to the player.
  final String path;

  final List<SubtitleFileRef> subtitleFiles;

  final int? sizeInBytes;

  bool get hasSubtitles => subtitleFiles.isNotEmpty;

  /// True when at least one subtitle track is worth studying.
  bool get hasStudyableSubtitles =>
      subtitleFiles.any((s) => s.isGoodStudyTrack);

  @override
  String toString() => 'VideoEntry($id, ${subtitleFiles.length} subs)';
}

/// One episode within a series title.
@immutable
class SeriesEpisode {
  const SeriesEpisode({
    required this.videoId,
    required this.displayName,
    this.season,
    this.episode,
    this.episodeTitle,
  });

  final String videoId;

  /// What to show in a list.
  final String displayName;

  final int? season;
  final int? episode;
  final String? episodeTitle;

  /// True when neither a season nor an episode number could be read, which
  /// means the file sorts by name among the extras.
  bool get isUnnumbered => season == null && episode == null;

  @override
  String toString() =>
      'SeriesEpisode(s${season ?? '-'}e${episode ?? '-'}, $videoId)';
}

/// A title in the library: either a standalone video or a series.
@immutable
class MediaTitle {
  const MediaTitle.standalone({
    required this.name,
    required String this.videoId,
  })  : isSeries = false,
        episodes = const [];

  const MediaTitle.series({
    required this.name,
    required this.episodes,
  })  : isSeries = true,
        videoId = null;

  /// Display name, cleaned of release metadata.
  final String name;

  final bool isSeries;

  /// Set for a standalone title only.
  final String? videoId;

  /// Set for a series only, in viewing order.
  final List<SeriesEpisode> episodes;

  int get partCount => isSeries ? episodes.length : 1;

  /// Season numbers present, ascending. Empty for a flat series.
  List<int> get seasons =>
      episodes.map((e) => e.season).whereType<int>().toSet().toList()..sort();

  List<SeriesEpisode> episodesInSeason(int season) =>
      episodes.where((e) => e.season == season).toList();

  @override
  String toString() =>
      'MediaTitle($name, ${isSeries ? '${episodes.length} episodes' : 'single'})';
}

/// The result of scanning one collection root.
@immutable
class MediaCollectionIndex {
  MediaCollectionIndex({
    required this.rootPath,
    required this.videos,
    required this.titles,
    this.unmatchedSubtitles = const [],
  });

  static final MediaCollectionIndex empty = MediaCollectionIndex(
    rootPath: '',
    videos: const [],
    titles: const [],
  );

  final String rootPath;

  /// Every video found, keyed by [VideoEntry.id].
  final List<VideoEntry> videos;

  /// Titles in display order.
  final List<MediaTitle> titles;

  /// Subtitle files that could not be attached to any video. Surfacing these
  /// is how a user finds out their naming is off, instead of silently getting
  /// a library with no subtitles.
  final List<String> unmatchedSubtitles;

  late final Map<String, VideoEntry> _byId = {
    for (final video in videos) video.id: video,
  };

  VideoEntry? videoById(String id) => _byId[id];

  MediaTitle? titleForVideo(String videoId) => titles.firstWhereOrNull(
        (title) =>
            title.videoId == videoId ||
            title.episodes.any((e) => e.videoId == videoId),
      );

  int get videoCount => videos.length;

  @override
  String toString() =>
      'MediaCollectionIndex($rootPath, ${videos.length} videos, '
      '${titles.length} titles)';
}

/// A user-registered collection root.
@immutable
class MediaCollection {
  const MediaCollection({required this.name, required this.rootPath});

  final String name;
  final String rootPath;

  Map<String, Object?> toJson() => {'name': name, 'rootPath': rootPath};

  static MediaCollection fromJson(Map<String, Object?> json) => MediaCollection(
        name: json['name']! as String,
        rootPath: json['rootPath']! as String,
      );

  @override
  bool operator ==(Object other) =>
      other is MediaCollection &&
      other.name == name &&
      other.rootPath == rootPath;

  @override
  int get hashCode => Object.hash(name, rootPath);

  @override
  String toString() => 'MediaCollection($name, $rootPath)';
}
