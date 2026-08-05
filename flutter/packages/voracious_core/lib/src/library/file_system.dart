/// The filesystem interface the library scanner works against.
///
/// Scanning is the part of the app most likely to break on a platform: Android
/// hands out content URIs through the Storage Access Framework rather than
/// paths, iOS sandboxes everything behind security-scoped bookmarks, and a TV
/// build may be reading from SMB or DLNA rather than local storage. None of
/// that changes how a collection is organised, so the scanner is written
/// against this interface and each platform supplies the adapter.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// One entry in a directory listing.
@immutable
class FileSystemEntry {
  const FileSystemEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.sizeInBytes,
    this.modified,
  });

  /// Base name, including extension.
  final String name;

  /// Full path, as this filesystem addresses it.
  final String path;

  final bool isDirectory;
  final int? sizeInBytes;
  final DateTime? modified;

  bool get isFile => !isDirectory;

  /// Lower-case extension without the dot, or an empty string.
  String get extension {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  /// Name without its extension.
  String get baseName {
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  @override
  String toString() => '${isDirectory ? 'dir' : 'file'}:$path';
}

/// Read-only filesystem access, which is all scanning and subtitle loading
/// need.
abstract interface class MediaFileSystem {
  /// Lists [path]. Throws if it is not a readable directory.
  Future<List<FileSystemEntry>> list(String path);

  /// True when [path] exists and is a directory.
  Future<bool> directoryExists(String path);

  /// True when [path] exists and is a file.
  Future<bool> fileExists(String path);

  /// Reads a whole file. Subtitle files are small; video files are never read
  /// through this interface.
  Future<Uint8List> readBytes(String path);

  /// Joins path segments the way this filesystem addresses them.
  String join(String part1, [String? part2, String? part3]);

  /// The portion of [path] below [from].
  String relative(String path, {required String from});
}

/// An in-memory filesystem, for tests and for previewing a scan.
///
/// Paths are POSIX-style regardless of host, so scanner tests behave the same
/// on a Windows CI machine.
class InMemoryFileSystem implements MediaFileSystem {
  InMemoryFileSystem([Map<String, Object>? files]) {
    files?.forEach((path, content) {
      if (content is String) {
        addFile(path, utf8.encode(content));
      } else if (content is List<int>) {
        addFile(path, Uint8List.fromList(content));
      } else {
        throw ArgumentError.value(content, path, 'must be String or List<int>');
      }
    });
  }

  final Map<String, Uint8List> _files = {};
  final Set<String> _directories = {'/'};

  /// Adds a file, creating parent directories.
  void addFile(String path, [List<int> content = const []]) {
    final normalized = p.posix.normalize(path);
    _files[normalized] = Uint8List.fromList(content);
    var parent = p.posix.dirname(normalized);
    while (
        parent.isNotEmpty && parent != '.' && !_directories.contains(parent)) {
      _directories.add(parent);
      final next = p.posix.dirname(parent);
      if (next == parent) break;
      parent = next;
    }
  }

  /// Adds an empty directory.
  void addDirectory(String path) {
    var current = p.posix.normalize(path);
    while (current.isNotEmpty &&
        current != '.' &&
        !_directories.contains(current)) {
      _directories.add(current);
      final next = p.posix.dirname(current);
      if (next == current) break;
      current = next;
    }
  }

  @override
  Future<List<FileSystemEntry>> list(String path) async {
    final directory = p.posix.normalize(path);
    if (!_directories.contains(directory)) {
      throw FileSystemException('not a directory', directory);
    }

    final entries = <String, FileSystemEntry>{};

    for (final file in _files.keys) {
      if (p.posix.dirname(file) != directory) continue;
      final name = p.posix.basename(file);
      entries[name] = FileSystemEntry(
        name: name,
        path: file,
        isDirectory: false,
        sizeInBytes: _files[file]!.length,
      );
    }

    for (final dir in _directories) {
      if (dir == directory || p.posix.dirname(dir) != directory) continue;
      final name = p.posix.basename(dir);
      entries[name] = FileSystemEntry(
        name: name,
        path: dir,
        isDirectory: true,
      );
    }

    final result = entries.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  @override
  Future<bool> directoryExists(String path) async =>
      _directories.contains(p.posix.normalize(path));

  @override
  Future<bool> fileExists(String path) async =>
      _files.containsKey(p.posix.normalize(path));

  @override
  Future<Uint8List> readBytes(String path) async {
    final content = _files[p.posix.normalize(path)];
    if (content == null) throw FileSystemException('no such file', path);
    return content;
  }

  @override
  String join(String part1, [String? part2, String? part3]) =>
      p.posix.join(part1, part2, part3);

  @override
  String relative(String path, {required String from}) =>
      p.posix.relative(path, from: from);
}

/// Raised when a filesystem operation cannot be completed.
class FileSystemException implements Exception {
  const FileSystemException(this.message, this.path);

  final String message;
  final String path;

  @override
  String toString() => 'FileSystemException: $message ($path)';
}
