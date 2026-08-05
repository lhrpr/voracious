/// Walks a collection root and works out what is in it.
///
/// The organisation it expects is the Kodi/Plex convention the Electron app
/// already required — a directory per title, optional `Season N` directories,
/// subtitles named after the video they belong to — with the tolerances that
/// real collections need: `Subs/` folders, anime-style flat numbering, and
/// release-group clutter in every name.
library;

import 'package:meta/meta.dart';

import '../language/subtitle_language_tag.dart';
import '../subtitles/subtitle_format.dart';
import 'episode_parsing.dart';
import 'file_system.dart';
import 'media_library.dart';

/// Tuning for a scan.
@immutable
class ScanOptions {
  const ScanOptions({
    this.maxDepth = 4,
    this.videoExtensions = videoFileExtensions,
    this.followSubtitleDirectories = true,
    this.minimumVideoBytes = 0,
  });

  /// How deep below the collection root to look. Four levels covers
  /// `root/Show/Season 1/Episode.mkv` with one to spare.
  final int maxDepth;

  final Set<String> videoExtensions;

  /// Also collect subtitles from `Subs/` folders next to the videos.
  final bool followSubtitleDirectories;

  /// Ignore video files smaller than this. Useful for skipping the sample
  /// clips that ship with scene releases; zero disables the check.
  final int minimumVideoBytes;
}

/// Progress from a running scan.
@immutable
class ScanProgress {
  const ScanProgress({
    required this.currentPath,
    required this.directoriesScanned,
    required this.videosFound,
  });

  final String currentPath;
  final int directoriesScanned;
  final int videosFound;

  @override
  String toString() =>
      'ScanProgress($directoriesScanned dirs, $videosFound videos)';
}

/// Scans collection roots into a [MediaCollectionIndex].
class MediaScanner {
  MediaScanner({
    required this.fileSystem,
    this.options = const ScanOptions(),
  });

  final MediaFileSystem fileSystem;
  final ScanOptions options;

  /// Scans [rootPath].
  ///
  /// A missing or unreadable root yields an empty index rather than throwing:
  /// an external drive being unplugged is a normal state for a media library,
  /// and it should not stop the app from starting.
  Future<MediaCollectionIndex> scan(
    String rootPath, {
    void Function(ScanProgress progress)? onProgress,
  }) async {
    if (!await fileSystem.directoryExists(rootPath)) {
      return MediaCollectionIndex(
        rootPath: rootPath,
        videos: const [],
        titles: const [],
      );
    }

    final state = _ScanState(rootPath, onProgress);
    final root = await _scanDirectory(rootPath, 0, state);

    final videos = <VideoEntry>[];
    final titles = <MediaTitle>[];

    // Videos sitting directly in the root are standalone titles.
    for (final video in root.videos) {
      videos.add(video);
      titles.add(MediaTitle.standalone(
        name: prettifyTitle(video.name),
        videoId: video.id,
      ));
    }

    for (final child in root.children) {
      final collected = <_NumberedVideo>[];
      _collectVideos(child, null, collected);
      if (collected.isEmpty) continue;

      videos.addAll(collected.map((c) => c.video));

      final title = _buildTitle(child.name, collected);
      if (title != null) titles.add(title);
    }

    titles.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return MediaCollectionIndex(
      rootPath: rootPath,
      videos: videos,
      titles: titles,
      unmatchedSubtitles: state.unmatchedSubtitles,
    );
  }

  /// Reads one directory, pairs its subtitles, and recurses.
  Future<_DirectoryScan> _scanDirectory(
    String path,
    int depth,
    _ScanState state,
  ) async {
    state.enter(path);

    List<FileSystemEntry> entries;
    try {
      entries = await fileSystem.list(path);
    } on Object {
      // An unreadable directory should cost us that directory, nothing more.
      return _DirectoryScan(path: path, name: _baseName(path));
    }

    final videoFiles = <FileSystemEntry>[];
    final subtitleFiles = <FileSystemEntry>[];
    final subdirectories = <FileSystemEntry>[];
    final subtitleDirectories = <FileSystemEntry>[];

    for (final entry in entries) {
      if (entry.isDirectory) {
        if (options.followSubtitleDirectories &&
            subtitleDirectoryNames.contains(entry.name.toLowerCase())) {
          subtitleDirectories.add(entry);
        } else {
          subdirectories.add(entry);
        }
        continue;
      }

      if (options.videoExtensions.contains(entry.extension)) {
        final size = entry.sizeInBytes;
        if (options.minimumVideoBytes > 0 &&
            size != null &&
            size < options.minimumVideoBytes) {
          continue;
        }
        videoFiles.add(entry);
      } else if (SubtitleFormat.fromPath(entry.name) != null) {
        subtitleFiles.add(entry);
      }
    }

    // Subtitles in a `Subs/` folder belong to the videos in this directory.
    final loose = <FileSystemEntry>[];
    for (final directory in subtitleDirectories) {
      loose.addAll(await _collectSubtitleDirectory(directory.path, state));
    }

    final videos = _pairSubtitles(
      videoFiles: videoFiles,
      subtitleFiles: [...subtitleFiles, ...loose],
      state: state,
    );
    state.addVideos(videos.length, path);

    final scan = _DirectoryScan(
      path: path,
      name: _baseName(path),
      videos: videos,
      seasonNumber: parseSeasonDirectory(_baseName(path)),
    );

    if (depth < options.maxDepth) {
      for (final directory in subdirectories) {
        scan.children
            .add(await _scanDirectory(directory.path, depth + 1, state));
      }
    }

    return scan;
  }

  /// Reads a `Subs/` folder, including one level of per-episode subfolders.
  Future<List<FileSystemEntry>> _collectSubtitleDirectory(
    String path,
    _ScanState state,
  ) async {
    final result = <FileSystemEntry>[];
    List<FileSystemEntry> entries;
    try {
      entries = await fileSystem.list(path);
    } on Object {
      return result;
    }

    for (final entry in entries) {
      if (entry.isDirectory) {
        try {
          result.addAll((await fileSystem.list(entry.path)).where(
              (e) => e.isFile && SubtitleFormat.fromPath(e.name) != null));
        } on Object {
          // Ignore unreadable subfolders.
        }
      } else if (SubtitleFormat.fromPath(entry.name) != null) {
        result.add(entry);
      }
    }
    return result;
  }

  /// Attaches each subtitle file to the video it belongs to.
  ///
  /// Exact base-name match first, then prefix match, then — when the directory
  /// holds exactly one video — everything left over, which is what makes
  /// `Movie/Subs/2_English.srt` work.
  List<VideoEntry> _pairSubtitles({
    required List<FileSystemEntry> videoFiles,
    required List<FileSystemEntry> subtitleFiles,
    required _ScanState state,
  }) {
    final attached = <String, List<SubtitleFileRef>>{
      for (final video in videoFiles) video.path: <SubtitleFileRef>[],
    };

    final videoBaseNames = {
      for (final video in videoFiles) video.path: video.baseName.toLowerCase(),
    };

    for (final subtitle in subtitleFiles) {
      final tag = parseSubtitleLanguageTag(subtitle.name);
      final base = tag.baseName.toLowerCase();

      String? target = videoFiles
          .map((v) => v.path)
          .where((path) => videoBaseNames[path] == base)
          .firstOrNull;

      target ??= _bestPrefixMatch(base, videoBaseNames);

      if (target == null && videoFiles.length == 1) {
        target = videoFiles.single.path;
      }

      if (target == null) {
        state.unmatchedSubtitles.add(subtitle.path);
        continue;
      }

      attached[target]!.add(SubtitleFileRef(
        id: state.relativeId(subtitle.path),
        path: subtitle.path,
        format: SubtitleFormat.fromPath(subtitle.name)!,
        languageCode: tag.iso6393,
        label: tag.label,
        forced: tag.forced,
        hearingImpaired: tag.hearingImpaired,
      ));
    }

    return [
      for (final video in videoFiles)
        VideoEntry(
          id: state.relativeId(video.path),
          name: video.baseName,
          path: video.path,
          sizeInBytes: video.sizeInBytes,
          subtitleFiles: attached[video.path]!
            ..sort((a, b) => a.id.compareTo(b.id)),
        ),
    ];
  }

  /// Longest video base name that [subtitleBase] starts with (or that starts
  /// with it), guarding against `Show S01E01` matching `Show S01E010`.
  String? _bestPrefixMatch(
      String subtitleBase, Map<String, String> videoBases) {
    String? best;
    var bestLength = 0;
    videoBases.forEach((path, base) {
      if (base.isEmpty || subtitleBase.isEmpty) return;
      final matches =
          subtitleBase.startsWith(base) || base.startsWith(subtitleBase);
      if (!matches) return;
      // Require a real overlap, not a one-character coincidence.
      final overlap =
          base.length < subtitleBase.length ? base.length : subtitleBase.length;
      if (overlap < 4) return;
      if (overlap > bestLength) {
        bestLength = overlap;
        best = path;
      }
    });
    return best;
  }

  /// Flattens a directory subtree into videos tagged with the season directory
  /// they were found under.
  void _collectVideos(
    _DirectoryScan scan,
    int? inheritedSeason,
    List<_NumberedVideo> out,
  ) {
    final season = scan.seasonNumber ?? inheritedSeason;
    for (final video in scan.videos) {
      out.add(_NumberedVideo(video, season));
    }
    for (final child in scan.children) {
      _collectVideos(child, season, out);
    }
  }

  /// Decides whether a directory's videos form a series or a single title.
  MediaTitle? _buildTitle(String directoryName, List<_NumberedVideo> videos) {
    final name = prettifyTitle(directoryName);
    if (videos.isEmpty) return null;

    if (videos.length == 1) {
      final only = videos.single;
      // A lone file with episode numbering is still a series — the rest of the
      // season may simply not be downloaded yet.
      final numbering = parseEpisodeNumbering(only.video.name);
      if (numbering == null && only.seasonFromDirectory == null) {
        return MediaTitle.standalone(name: name, videoId: only.video.id);
      }
    }

    final episodes = <SeriesEpisode>[];
    for (final entry in videos) {
      final numbering = parseEpisodeNumbering(entry.video.name);
      episodes.add(SeriesEpisode(
        videoId: entry.video.id,
        displayName: prettifyTitle(entry.video.name),
        season: numbering?.season ?? entry.seasonFromDirectory,
        episode: numbering?.episode,
        episodeTitle: numbering?.title,
      ));
    }

    episodes.sort(_compareEpisodes);
    return MediaTitle.series(name: name, episodes: episodes);
  }

  static int _compareEpisodes(SeriesEpisode a, SeriesEpisode b) {
    // Files with no numbering at all sort last overall.
    if (a.isUnnumbered != b.isUnnumbered) return a.isUnnumbered ? 1 : -1;

    final seasonA = a.season ?? -1;
    final seasonB = b.season ?? -1;
    if (seasonA != seasonB) return seasonA.compareTo(seasonB);

    // Within a season, extras with no episode number go after the episodes.
    final hasEpisodeA = a.episode != null;
    final hasEpisodeB = b.episode != null;
    if (hasEpisodeA != hasEpisodeB) return hasEpisodeA ? -1 : 1;
    if (hasEpisodeA && a.episode != b.episode) {
      return a.episode!.compareTo(b.episode!);
    }

    return a.displayName.compareTo(b.displayName);
  }

  static String _baseName(String path) {
    final normalized =
        path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final slash = normalized.lastIndexOf(RegExp(r'[/\\]'));
    return slash < 0 ? normalized : normalized.substring(slash + 1);
  }
}

class _DirectoryScan {
  _DirectoryScan({
    required this.path,
    required this.name,
    this.videos = const [],
    this.seasonNumber,
  });

  final String path;
  final String name;
  final List<VideoEntry> videos;
  final int? seasonNumber;
  final List<_DirectoryScan> children = [];
}

class _NumberedVideo {
  _NumberedVideo(this.video, this.seasonFromDirectory);

  final VideoEntry video;
  final int? seasonFromDirectory;
}

class _ScanState {
  _ScanState(this.rootPath, this.onProgress);

  final String rootPath;
  final void Function(ScanProgress progress)? onProgress;
  final List<String> unmatchedSubtitles = [];

  int _directories = 0;
  int _videos = 0;

  void enter(String path) {
    _directories++;
    _report(path);
  }

  void addVideos(int count, String path) {
    if (count == 0) return;
    _videos += count;
    _report(path);
  }

  void _report(String path) => onProgress?.call(ScanProgress(
        currentPath: path,
        directoriesScanned: _directories,
        videosFound: _videos,
      ));

  /// Collection-relative id for [path], with forward slashes on every platform
  /// so ids stay portable between a desktop and a phone reading the same NAS.
  String relativeId(String path) {
    var relative = path;
    if (path.startsWith(rootPath)) {
      relative = path.substring(rootPath.length);
    }
    relative = relative.replaceAll(r'\', '/');
    while (relative.startsWith('/')) {
      relative = relative.substring(1);
    }
    return relative;
  }
}
