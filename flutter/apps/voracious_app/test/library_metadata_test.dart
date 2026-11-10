/// The library screen with matched metadata: titles and episode names come
/// from the match, and the per-title menu reaches "Fix match".
///
/// Matches are seeded into the cache beforehand, so nothing here touches the
/// network — a fresh cached match is never looked up again.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voracious_app/src/screens/library_screen.dart';
import 'package:voracious_app/src/state/library_controller.dart';
import 'package:voracious_app/src/state/library_metadata.dart';
import 'package:voracious_core/voracious_core.dart';

class _CannedTransport implements MetadataTransport {
  @override
  Future<MetadataHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async =>
      switch (url.path) {
        '/search/shows' => MetadataHttpResponse(
            200,
            jsonEncode([
              {
                'show': {'id': 385, 'name': 'Mad Men', 'premiered': '2007-07-19'},
              },
            ])),
        '/shows/385' => MetadataHttpResponse(
            200,
            jsonEncode({
              'id': 385,
              'name': 'Mad Men',
              'premiered': '2007-07-19',
              'genres': ['Drama'],
              'summary': '<p>Advertising in 1960s New York.</p>',
              '_embedded': {
                'episodes': [
                  {'season': 3, 'number': 7, 'name': 'Seven Twenty Three'},
                ],
              },
            })),
        _ => const MetadataHttpResponse(404, ''),
      };
}

void main() {
  late Directory library;
  late LibraryController controller;

  setUp(() async {
    library = await Directory.systemTemp.createTemp('voracious_metadata');
    for (final path in [
      'Mad Men (2007)/Season 3/Mad.Men.S03E07.720p.mkv',
      'Mad Men (2007)/Season 3/Mad.Men.S03E08.720p.mkv',
      'Mad.Men.S03E07.mkv',
    ]) {
      await File('${library.path}/$path').create(recursive: true);
    }

    final cache = InMemoryKeyValueStore();
    // What an earlier session's lookup would have left behind.
    await MetadataService(
      cache: cache,
      providers: [TvMazeProvider(transport: _CannedTransport())],
      signature: const MetadataSettings().signature,
    ).match(const MetadataQuery(
        kind: MetadataKind.series, name: 'Mad Men', year: 2007));
    await MetadataService(
      cache: cache,
      providers: [TvMazeProvider(transport: _CannedTransport())],
      signature: const MetadataSettings().signature,
    ).match(const MetadataQuery(kind: MetadataKind.series, name: 'Mad Men'));

    controller = LibraryController(
      profiles: ProfileRepository(InMemoryKeyValueStore()),
      metadata: LibraryMetadata(cache: cache),
    );
    await controller.load();
    await controller.addCollection(library.path, name: 'Test');
  });

  tearDown(() async {
    controller.dispose();
    await library.delete(recursive: true);
  });

  testWidgets('shows matched names, episode titles and the fix-match menu',
      (tester) async {
    // Let the background matching pass read the cache.
    await tester.runAsync(() async {
      while (controller.metadata!.isMatching ||
          controller.metadata!.metadataFor(controller.index.titles.first) ==
              null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });

    await tester.binding.setSurfaceSize(const Size(1200, 800));
    await tester.pumpWidget(MaterialApp(
      home: LibraryScreen(controller: controller),
    ));
    await tester.pump();

    // The loose file is labelled as the episode it is.
    expect(find.text('Mad Men · S03E07 · Seven Twenty Three'), findsOneWidget);
    // The series folder shows the year and genre from the match.
    expect(find.text('2007 · 2 episodes · Drama'), findsOneWidget);

    await tester.tap(find.text('2007 · 2 episodes · Drama'));
    await tester.pumpAndSettle();
    expect(find.text('S03E07 · Seven Twenty Three'), findsOneWidget);
    expect(find.text('Advertising in 1960s New York.'), findsOneWidget);
    // An episode the listing lacks keeps its file name.
    expect(find.textContaining('S03E08'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.text('Fix match…'), findsOneWidget);
    expect(find.text('Refresh metadata'), findsOneWidget);
  });
}
