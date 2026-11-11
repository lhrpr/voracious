/// The library screen: collections on the left, titles on the right.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:voracious_core/voracious_core.dart';
import 'package:voracious_core/voracious_core_io.dart' show IoArtworkCache;

import '../state/library_controller.dart';
import '../state/library_metadata.dart';
import '../widgets/artwork_image.dart';
import '../widgets/transport_bar.dart' show formatDuration;
import 'about_screen.dart';
import 'fix_match_dialog.dart';
import 'player_screen.dart';
import 'settings_screen.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key, required this.controller});

  final LibraryController controller;

  Future<void> _addCollection(BuildContext context) async {
    final path = await getDirectoryPath(
      confirmButtonText: 'Add collection',
    );
    if (path != null) await controller.addCollection(path);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
            title: const Text('Voracious'),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Rescan',
                onPressed: controller.selected == null ||
                        controller.status == ScanStatus.scanning
                    ? null
                    : controller.rescan,
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Settings',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsScreen(
                      initial: controller.preferences,
                      onChanged: controller.updatePreferences,
                      showMetadata: controller.metadata != null,
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.info_outline),
                tooltip: 'About',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AboutScreen(),
                  ),
                ),
              ),
            ],
          ),
          body: !controller.isLoaded
              ? const Center(child: CircularProgressIndicator())
              : Row(
                  children: [
                    SizedBox(
                      width: 240,
                      child: _CollectionList(
                        controller: controller,
                        onAdd: () => _addCollection(context),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: _TitleList(
                        controller: controller,
                        onAdd: () => _addCollection(context),
                      ),
                    ),
                  ],
                ),
        ),
      );
}

class _CollectionList extends StatelessWidget {
  const _CollectionList({required this.controller, required this.onAdd});

  final LibraryController controller;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                for (final collection in controller.collections)
                  ListTile(
                    dense: true,
                    selected: collection == controller.selected,
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(
                      collection.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      collection.rootPath,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10),
                    ),
                    onTap: () => controller.select(collection),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.refresh, size: 16),
                          tooltip: 'Rescan folder',
                          // Selecting a collection always rescans it.
                          onPressed: controller.status == ScanStatus.scanning
                              ? null
                              : () => controller.select(collection),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          tooltip: 'Remove from library',
                          onPressed: () =>
                              controller.removeCollection(collection),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(8),
            child: SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add folder'),
                onPressed: onAdd,
              ),
            ),
          ),
        ],
      );
}

class _TitleList extends StatelessWidget {
  const _TitleList({required this.controller, required this.onAdd});

  final LibraryController controller;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    if (controller.collections.isEmpty) {
      return _Empty(onAdd: onAdd);
    }

    switch (controller.status) {
      case ScanStatus.scanning:
        final progress = controller.progress;
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                progress == null
                    ? 'Scanning…'
                    : 'Scanning — ${progress.videosFound} videos in '
                        '${progress.directoriesScanned} folders',
              ),
            ],
          ),
        );

      case ScanStatus.failed:
        return Center(child: Text('Scan failed: ${controller.error}'));

      case ScanStatus.idle:
        return const Center(child: Text('Select a collection'));

      case ScanStatus.ready:
        break;
    }

    final index = controller.index;
    if (index.titles.isEmpty) {
      return const Center(
        child: Text('No videos found in this folder'),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (controller.metadata case final metadata?)
          _MetadataStatus(metadata: metadata),
        for (final title in index.titles)
          _TitleTile(title: title, controller: controller),
        if (index.unmatchedSubtitles.isNotEmpty)
          _UnmatchedSubtitles(paths: index.unmatchedSubtitles),
      ],
    );
  }
}

class _TitleTile extends StatelessWidget {
  const _TitleTile({required this.title, required this.controller});

  final MediaTitle title;
  final LibraryController controller;

  void _play(BuildContext context, String videoId) {
    final video = controller.index.videoById(videoId);
    if (video == null) return;

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(video: video, library: controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final metadata = controller.metadata;
    final match = metadata?.metadataFor(title);
    final artwork = metadata?.artwork;
    final menu = _TitleMenu(title: title, controller: controller);

    final poster = ArtworkImage(
      url: match?.posterUrl,
      cache: artwork,
      width: 40,
      height: 60,
      placeholderIcon:
          title.isSeries ? Icons.video_library_outlined : Icons.movie_outlined,
    );

    if (!title.isSeries) {
      final video = controller.index.videoById(title.videoId!);
      final numbering = metadata?.episodeNumberingOf(title);
      final episode = metadata?.standaloneEpisodeFor(title);
      final name = match?.name ?? title.name;
      final heading = numbering == null
          ? (match?.year == null ? name : '$name (${match!.year})')
          : [
              name,
              episodeLabel(numbering.season, numbering.episode),
              if (episode != null && episode.name.isNotEmpty) episode.name,
            ].join(' · ');
      return ListTile(
        leading: poster,
        title: Text(heading),
        subtitle: _SubtitleSummary(
          video: video,
          position: controller.positions[title.videoId],
        ),
        trailing: menu,
        onTap: () => _play(context, title.videoId!),
      );
    }

    final year = match?.year ?? title.year;
    final summary = [
      if (year != null) '$year',
      '${title.episodes.length} episodes',
      if (match != null && match.genres.isNotEmpty)
        match.genres.take(2).join(', '),
    ].join(' · ');

    return ExpansionTile(
      leading: poster,
      title: Text(match?.name ?? title.name),
      subtitle: Text(summary),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [menu, const Icon(Icons.expand_more)],
      ),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (match?.overview case final overview?)
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 24, 12),
            child: Text(
              overview,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        for (final episode in title.episodes)
          _EpisodeTile(
            episode: episode,
            listing: metadata?.episodeFor(title, episode),
            showStill: match != null,
            artwork: artwork,
            video: controller.index.videoById(episode.videoId),
            position: controller.positions[episode.videoId],
            onTap: () => _play(context, episode.videoId),
          ),
      ],
    );
  }
}

/// `S03E07`, `E05` for a flat series, or empty with no number.
String episodeLabel(int? season, int? episode) {
  if (episode == null) return season == null ? '' : 'Season $season';
  final e = 'E${episode.toString().padLeft(2, '0')}';
  return season == null ? e : 'S${season.toString().padLeft(2, '0')}$e';
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.episode,
    required this.listing,
    required this.showStill,
    required this.artwork,
    required this.video,
    required this.position,
    required this.onTap,
  });

  final SeriesEpisode episode;

  /// The service's entry for this episode, when the series is matched and
  /// lists it.
  final EpisodeMetadata? listing;

  /// Whether to leave room for a still. Off for an unmatched series, which
  /// would otherwise be a column of placeholders.
  final bool showStill;
  final IoArtworkCache? artwork;
  final VideoEntry? video;
  final Duration? position;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final listed = listing;
    final label = episodeLabel(episode.season, episode.episode);
    final title = listed != null && listed.name.isNotEmpty
        ? (label.isEmpty ? listed.name : '$label · ${listed.name}')
        : episode.displayName;

    final row = ListTile(
      contentPadding: EdgeInsets.only(left: showStill ? 72 : 56, right: 16),
      dense: true,
      leading: showStill
          ? ArtworkImage(
              url: listed?.stillUrl,
              cache: artwork,
              width: 80,
              height: 45,
              placeholderIcon: Icons.play_arrow_outlined,
            )
          : null,
      title: Text(title),
      subtitle: _SubtitleSummary(video: video, position: position),
      onTap: onTap,
    );

    final overview = listed?.overview;
    if (overview == null) return row;
    return Tooltip(
      message: overview,
      waitDuration: const Duration(milliseconds: 700),
      constraints: const BoxConstraints(maxWidth: 420),
      child: row,
    );
  }
}

/// Fix match and refresh, for one title.
class _TitleMenu extends StatelessWidget {
  const _TitleMenu({required this.title, required this.controller});

  final MediaTitle title;
  final LibraryController controller;

  @override
  Widget build(BuildContext context) {
    final metadata = controller.metadata;
    if (metadata == null ||
        !metadata.settings.enabled ||
        metadata.queryFor(title) == null) {
      return const SizedBox.shrink();
    }
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 18),
      tooltip: 'Metadata',
      onSelected: (action) async {
        switch (action) {
          case 'fix':
            await showFixMatchDialog(context, metadata, title);
          case 'refresh':
            await metadata.refresh(title);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'fix', child: Text('Fix match…')),
        PopupMenuItem(value: 'refresh', child: Text('Refresh metadata')),
      ],
    );
  }
}

/// What a row says about a video: how many subtitle tracks it has, and how far
/// in the user got. Both are the questions actually asked when choosing what
/// to watch next.
class _SubtitleSummary extends StatelessWidget {
  const _SubtitleSummary({required this.video, this.position});

  final VideoEntry? video;
  final Duration? position;

  @override
  Widget build(BuildContext context) {
    final entry = video;
    if (entry == null) return const SizedBox.shrink();

    final languages = entry.subtitleFiles
        .map((s) => s.languageCode == null
            ? null
            : (languageName(s.languageCode!) ?? s.languageCode))
        .whereType<String>()
        .toSet()
        .toList();

    final parts = <String>[
      if (entry.subtitleFiles.isEmpty)
        'no subtitles'
      else if (languages.isEmpty)
        '${entry.subtitleFiles.length} subtitle files'
      else
        languages.join(', '),
      if (position != null && position! > Duration.zero)
        'resume at ${formatDuration(position!)}',
    ];

    return Text(
      parts.join(' · '),
      style: TextStyle(
        fontSize: 11,
        color: entry.hasStudyableSubtitles ? null : Theme.of(context).hintColor,
      ),
    );
  }
}

/// A line above the titles while metadata is being looked up, or when the
/// last lookup failed.
class _MetadataStatus extends StatelessWidget {
  const _MetadataStatus({required this.metadata});

  final LibraryMetadata metadata;

  @override
  Widget build(BuildContext context) {
    final error = metadata.error;
    if (!metadata.isMatching && error == null) return const SizedBox.shrink();
    final (done, total) = metadata.progress;
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          if (metadata.isMatching) ...[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text('Matching metadata — $done of $total', style: style),
          ],
          if (error != null) ...[
            if (metadata.isMatching) const SizedBox(width: 16),
            Icon(Icons.cloud_off, size: 14, color: style?.color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Metadata: $error',
                style: style,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _UnmatchedSubtitles extends StatelessWidget {
  const _UnmatchedSubtitles({required this.paths});

  final List<String> paths;

  @override
  Widget build(BuildContext context) => ExpansionTile(
        leading: const Icon(Icons.warning_amber_outlined),
        title: Text('${paths.length} subtitle files matched no video'),
        subtitle: const Text(
          'Usually a naming mismatch between the subtitle and the video',
          style: TextStyle(fontSize: 11),
        ),
        children: [
          for (final path in paths)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 56, right: 16),
              title: Text(path, style: const TextStyle(fontSize: 11)),
            ),
        ],
      );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_open, size: 48),
            const SizedBox(height: 16),
            const Text('Add a folder of videos to get started'),
            const SizedBox(height: 8),
            const SizedBox(
              width: 420,
              child: Text(
                'Subtitles are picked up from beside each video, or from a '
                'Subs folder next to it.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add folder'),
              onPressed: onAdd,
            ),
          ],
        ),
      );
}
