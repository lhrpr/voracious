/// Pulls text subtitle tracks out of MKV files and caches them as ordinary
/// subtitle files, so the player can load them like sidecar files.
///
/// Extraction reads every block header in the file (a few seconds for a
/// feature film on an SSD, longer over a network), so it runs on a background
/// isolate and only happens once per file: the result is written under the
/// app's support directory, keyed on the file's path, size and modification
/// time, and reused from then on.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:voracious_core/voracious_core.dart';

class EmbeddedSubtitleCache {
  EmbeddedSubtitleCache({Future<Directory> Function()? root})
      : _root = root ?? _defaultRoot;

  final Future<Directory> Function() _root;

  static Future<Directory> _defaultRoot() async => Directory(
        p.join(
          (await getApplicationSupportDirectory()).path,
          'embedded_subtitles',
        ),
      );

  /// Bump to throw away caches written by an older extractor.
  static const _version = 1;

  /// Subtitle refs for every text track embedded in [video], extracting them
  /// first if they aren't cached yet. Empty for files that aren't Matroska.
  Future<List<SubtitleFileRef>> refsFor(VideoEntry video) async {
    final file = File(video.path);
    if (!await _isMatroska(file)) return const [];

    final stat = await file.stat();
    final key = _cacheKey(video.path, stat.size, stat.modified);
    final dir = Directory(p.join((await _root()).path, key));
    final manifestFile = File(p.join(dir.path, 'manifest.json'));

    List<_CachedTrack> tracks;
    if (await manifestFile.exists()) {
      tracks = _CachedTrack.listFromJson(await manifestFile.readAsString());
    } else {
      final extracted = await Isolate.run(() => _extract(video.path));
      await dir.create(recursive: true);
      tracks = [
        for (final e in extracted)
          _CachedTrack(
            number: e.number,
            fileName: 'track${e.number}.${e.format.extensions.first}',
            format: e.format,
            languageCode: e.languageCode,
            name: e.name,
            isForced: e.isForced,
            isHearingImpaired: e.isHearingImpaired,
          ),
      ];
      for (var i = 0; i < tracks.length; i++) {
        await File(p.join(dir.path, tracks[i].fileName))
            .writeAsString(extracted[i].contents);
      }
      // Written last, so an interrupted extraction is simply redone.
      await manifestFile.writeAsString(_CachedTrack.listToJson(tracks));
    }

    return [
      for (final t in tracks)
        SubtitleFileRef(
          id: '${video.id}#track${t.number}',
          path: p.join(dir.path, t.fileName),
          format: t.format,
          languageCode: t.languageCode,
          label: t.name ?? 'Embedded track ${t.number}',
          forced: t.isForced,
          hearingImpaired: t.isHearingImpaired,
        ),
    ];
  }

  static Future<bool> _isMatroska(File file) async {
    try {
      final handle = await file.open();
      try {
        return MatroskaSubtitleReader.looksLikeMatroska(await handle.read(4));
      } finally {
        await handle.close();
      }
    } on FileSystemException {
      return false;
    }
  }

  static String _cacheKey(String path, int size, DateTime modified) {
    // FNV-1a over the identity; collisions just mean a re-extraction.
    var hash = 0xcbf29ce484222325;
    for (final unit in utf8
        .encode('$_version|$path|$size|${modified.millisecondsSinceEpoch}')) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }
}

/// Runs on a background isolate: plain data in and out.
List<_Extracted> _extract(String path) {
  final file = File(path).openSync();
  try {
    final reader = MatroskaSubtitleReader(
      _FileByteSource(file),
      inflate: (bytes) => Uint8List.fromList(zlib.decode(bytes)),
    );
    return [
      for (final e in reader.extract())
        _Extracted(
          number: e.track.number,
          format: e.track.format!,
          languageCode: e.track.languageCode,
          name: e.track.name,
          isForced: e.track.isForced,
          isHearingImpaired: e.track.isHearingImpaired,
          contents: e.contents,
        ),
    ];
  } finally {
    file.closeSync();
  }
}

class _FileByteSource implements ByteSource {
  _FileByteSource(this._file) : length = _file.lengthSync();

  final RandomAccessFile _file;

  @override
  final int length;

  @override
  Uint8List read(int offset, int count) {
    _file.setPositionSync(offset);
    return _file.readSync(count);
  }
}

class _Extracted {
  const _Extracted({
    required this.number,
    required this.format,
    required this.languageCode,
    required this.name,
    required this.isForced,
    required this.isHearingImpaired,
    required this.contents,
  });

  final int number;
  final SubtitleFormat format;
  final String? languageCode;
  final String? name;
  final bool isForced;
  final bool isHearingImpaired;
  final String contents;
}

class _CachedTrack {
  const _CachedTrack({
    required this.number,
    required this.fileName,
    required this.format,
    required this.languageCode,
    required this.name,
    required this.isForced,
    required this.isHearingImpaired,
  });

  final int number;
  final String fileName;
  final SubtitleFormat format;
  final String? languageCode;
  final String? name;
  final bool isForced;
  final bool isHearingImpaired;

  Map<String, Object?> toJson() => {
        'number': number,
        'file': fileName,
        'format': format.name,
        'language': languageCode,
        'name': name,
        'forced': isForced,
        'hearingImpaired': isHearingImpaired,
      };

  static _CachedTrack fromJson(Map<String, Object?> json) => _CachedTrack(
        number: json['number']! as int,
        fileName: json['file']! as String,
        format: SubtitleFormat.values.byName(json['format']! as String),
        languageCode: json['language'] as String?,
        name: json['name'] as String?,
        isForced: json['forced'] as bool? ?? false,
        isHearingImpaired: json['hearingImpaired'] as bool? ?? false,
      );

  static String listToJson(List<_CachedTrack> tracks) =>
      jsonEncode([for (final t in tracks) t.toJson()]);

  static List<_CachedTrack> listFromJson(String source) => [
        for (final item in jsonDecode(source) as List<Object?>)
          fromJson(item! as Map<String, Object?>),
      ];
}
