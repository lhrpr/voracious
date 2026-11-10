/// Posters and episode stills, downloaded once and kept on disk.
///
/// Artwork URLs from both services are immutable — a new image gets a new
/// path — so a file named after its URL never needs revalidating.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

class IoArtworkCache {
  IoArtworkCache(this.directory, {Duration timeout = const Duration(seconds: 20)})
      : _timeout = timeout,
        _client = HttpClient()
          ..connectionTimeout = timeout
          ..userAgent = 'Voracious';

  final String directory;
  final Duration _timeout;
  final HttpClient _client;

  /// Downloads in flight, so a poster shown in two places is fetched once.
  final Map<String, Future<File?>> _pending = {};

  /// Images that failed this session; not retried until the next launch.
  final Set<String> _failed = {};

  /// The cached file for [url] if it is already on disk, without waiting.
  File? peek(String url) {
    final file = _fileFor(url);
    return file.existsSync() ? file : null;
  }

  /// The local file for [url], downloading it first if needed. Null when it
  /// cannot be fetched.
  Future<File?> fetch(String url) {
    final existing = peek(url);
    if (existing != null) return Future.value(existing);
    if (_failed.contains(url)) return Future.value();
    return _pending[url] ??= _download(url).whenComplete(() {
      _pending.remove(url);
    });
  }

  Future<File?> _download(String url) async {
    final file = _fileFor(url);
    try {
      final uri = Uri.parse(url);
      if (uri.scheme != 'https') throw ArgumentError('not https: $url');
      final request = await _client.getUrl(uri).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      await file.parent.create(recursive: true);
      // Written beside the target and renamed, so an interrupted download
      // never leaves a truncated image that looks cached.
      final partial = File('${file.path}.part');
      final sink = partial.openWrite();
      await response.timeout(_timeout).pipe(sink);
      await partial.rename(file.path);
      return file;
    } on Object {
      _failed.add(url);
      return null;
    }
  }

  File _fileFor(String url) {
    final uri = Uri.tryParse(url);
    var extension = p.extension(uri?.path ?? '').toLowerCase();
    if (!const {'.jpg', '.jpeg', '.png', '.webp'}.contains(extension)) {
      extension = '.img';
    }
    return File(p.join(directory, '${_fnv1a64(url)}$extension'));
  }

  /// FNV-1a, 64-bit, as hex: stable across runs and platforms, which
  /// `String.hashCode` is not promised to be.
  static String _fnv1a64(String text) {
    var hash = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = (BigInt.one << 64) - BigInt.one;
    for (final unit in text.codeUnits) {
      hash = ((hash ^ BigInt.from(unit)) * prime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  void close() => _client.close(force: true);
}
