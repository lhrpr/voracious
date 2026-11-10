/// Voracious for macOS.
library;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:voracious_core/voracious_core.dart';
import 'package:voracious_core/voracious_core_io.dart';

import 'src/screens/library_screen.dart';
import 'src/state/library_controller.dart';
import 'src/state/library_metadata.dart';
import 'src/storage/file_key_value_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final directory = await getApplicationSupportDirectory();
  final store = await FileKeyValueStore.open(directory.path);
  // Metadata gets a store of its own: episode listings are large next to the
  // profile, and keeping them apart means a playback-position save never
  // rewrites them.
  final metadataStore =
      await FileKeyValueStore.open(p.join(directory.path, 'metadata'));
  final controller = LibraryController(
    profiles: ProfileRepository(store),
    metadata: LibraryMetadata(
      cache: metadataStore,
      artwork: IoArtworkCache(p.join(directory.path, 'artwork')),
    ),
  );

  runApp(VoraciousApp(controller: controller));

  // Loading after the first frame means the window is already up while the
  // collection is being scanned, which on a large library is several seconds.
  await controller.load();
}

class VoraciousApp extends StatelessWidget {
  const VoraciousApp({super.key, required this.controller});

  final LibraryController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Voracious',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF2E7D6B),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: LibraryScreen(controller: controller),
      );
}
