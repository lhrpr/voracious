/// Tracks inside a media container, as reported by the playback engine.
library;

import 'package:meta/meta.dart';

import '../language/language_table.dart';

enum MediaTrackKind { video, audio, subtitle }

/// One track in the currently open file.
///
/// Embedded subtitle tracks are listed here but are not the same thing as the
/// external subtitle files the library scanner finds: these are rendered by the
/// engine and carry no analysed text. Extracting an embedded track for study is
/// a separate operation.
@immutable
class MediaTrack {
  const MediaTrack({
    required this.id,
    required this.kind,
    this.title,
    this.languageCode,
    this.codec,
    this.isDefault = false,
    this.isForced = false,
    this.isImageBased = false,
    this.channelCount,
    this.width,
    this.height,
  });

  /// Engine-assigned identifier, used to select the track.
  final int id;

  final MediaTrackKind kind;

  /// Track title from the container, if it has one.
  final String? title;

  /// ISO 639-3 code, normalised from whatever the container declared.
  final String? languageCode;

  final String? codec;

  final bool isDefault;
  final bool isForced;

  /// True for VobSub/PGS subtitle tracks. These carry pictures, not text, so
  /// they cannot be analysed or looked up — only displayed.
  final bool isImageBased;

  final int? channelCount;
  final int? width;
  final int? height;

  /// English language name, falling back to the code, then to "Unknown".
  String get languageDisplayName {
    final code = languageCode;
    if (code == null) return 'Unknown';
    return languageName(code) ?? code;
  }

  /// A label suitable for a track menu.
  String get displayLabel {
    final parts = <String>[
      if (title != null && title!.isNotEmpty) title! else languageDisplayName,
      if (title != null && title!.isNotEmpty && languageCode != null)
        '($languageDisplayName)',
      if (isForced) '[forced]',
    ];
    return parts.join(' ');
  }

  @override
  bool operator ==(Object other) =>
      other is MediaTrack && other.id == id && other.kind == kind;

  @override
  int get hashCode => Object.hash(id, kind);

  @override
  String toString() => 'MediaTrack($kind #$id, $languageCode)';
}
