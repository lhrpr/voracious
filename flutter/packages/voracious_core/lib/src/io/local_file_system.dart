/// A [MediaFileSystem] over `dart:io`.
library;

import 'dart:io' as io;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../library/file_system.dart';

/// Reads the local filesystem.
///
/// Suitable for Windows, macOS, Linux, and for Android and iOS paths the app
/// already has permission for. Android collections chosen through the Storage
/// Access Framework arrive as content URIs instead and need their own
/// [MediaFileSystem].
class LocalFileSystem implements MediaFileSystem {
  const LocalFileSystem();

  @override
  Future<List<FileSystemEntry>> list(String path) async {
    final directory = io.Directory(path);
    if (!await directory.exists()) {
      throw FileSystemException('not a directory', path);
    }

    final entries = <FileSystemEntry>[];
    await for (final entity in directory.list(followLinks: false)) {
      final name = p.basename(entity.path);
      // Skip dot files: macOS resource forks and Windows thumbnail caches are
      // not media, and `.DS_Store` in every directory is noise.
      if (name.startsWith('.')) continue;

      final stat = await entity.stat();
      entries.add(FileSystemEntry(
        name: name,
        path: entity.path,
        isDirectory: stat.type == io.FileSystemEntityType.directory,
        sizeInBytes:
            stat.type == io.FileSystemEntityType.file ? stat.size : null,
        modified: stat.modified,
      ));
    }

    entries.sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }

  @override
  Future<bool> directoryExists(String path) => io.Directory(path).exists();

  @override
  Future<bool> fileExists(String path) => io.File(path).exists();

  @override
  Future<Uint8List> readBytes(String path) async {
    final file = io.File(path);
    if (!await file.exists()) {
      throw FileSystemException('no such file', path);
    }
    return file.readAsBytes();
  }

  @override
  String join(String part1, [String? part2, String? part3]) =>
      p.join(part1, part2, part3);

  @override
  String relative(String path, {required String from}) =>
      p.relative(path, from: from);
}
