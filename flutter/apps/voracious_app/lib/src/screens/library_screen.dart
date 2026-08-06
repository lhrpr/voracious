/// The library screen: collections on the left, titles on the right.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:voracious_core/voracious_core.dart';

import '../state/library_controller.dart';
import '../widgets/transport_bar.dart' show formatDuration;
import 'about_screen.dart';
import 'player_screen.dart';

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
                onPressed:
                    controller.selected == null ? null : controller.rescan,
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
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      tooltip: 'Remove from library',
                      onPressed: () => controller.removeCollection(collection),
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
    if (!title.isSeries) {
      final video = controller.index.videoById(title.videoId!);
      return ListTile(
        leading: const Icon(Icons.movie_outlined),
        title: Text(title.name),
        subtitle: _SubtitleSummary(
          video: video,
          position: controller.positions[title.videoId],
        ),
        onTap: () => _play(context, title.videoId!),
      );
    }

    return ExpansionTile(
      leading: const Icon(Icons.video_library_outlined),
      title: Text(title.name),
      subtitle: Text('${title.episodes.length} episodes'),
      children: [
        for (final episode in title.episodes)
          ListTile(
            contentPadding: const EdgeInsets.only(left: 56, right: 16),
            dense: true,
            title: Text(episode.displayName),
            subtitle: _SubtitleSummary(
              video: controller.index.videoById(episode.videoId),
              position: controller.positions[episode.videoId],
            ),
            onTap: () => _play(context, episode.videoId),
          ),
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
