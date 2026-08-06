/// Voracious for macOS.
library;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:voracious_core/voracious_core.dart';

import 'src/screens/library_screen.dart';
import 'src/state/library_controller.dart';
import 'src/storage/file_key_value_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final directory = await getApplicationSupportDirectory();
  final store = await FileKeyValueStore.open(directory.path);
  final controller = LibraryController(profiles: ProfileRepository(store));

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
