/// Parses mpv's `track-list` property into [MediaTrack]s.
library;

import 'dart:convert';

import '../../language/language_table.dart';
import '../media_track.dart';

/// Subtitle codecs that carry pictures rather than text.
///
/// They can be displayed by the engine but never analysed, tokenised or looked
/// up, so the UI has to keep them out of the study track list.
const Set<String> imageSubtitleCodecs = {
  'dvd_subtitle',
  'dvdsub',
  'hdmv_pgs_subtitle',
  'pgssub',
  'dvb_subtitle',
  'dvbsub',
  'xsub',
};

/// Parses the JSON mpv returns for `track-list`.
///
/// Malformed input yields an empty list rather than throwing: a track list is
/// informational, and losing it should not take playback down.
List<MediaTrack> parseMpvTrackList(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return const [];
  }
  if (decoded is! List) return const [];

  final tracks = <MediaTrack>[];
  for (final entry in decoded) {
    if (entry is! Map) continue;
    final track = _parseTrack(entry.cast<String, Object?>());
    if (track != null) tracks.add(track);
  }
  return tracks;
}

MediaTrack? _parseTrack(Map<String, Object?> entry) {
  final kind = switch (entry['type']) {
    'video' => MediaTrackKind.video,
    'audio' => MediaTrackKind.audio,
    'sub' => MediaTrackKind.subtitle,
    _ => null,
  };
  if (kind == null) return null;

  final id = (entry['id'] as num?)?.toInt();
  if (id == null) return null;

  final codec = entry['codec'] as String?;
  final rawLanguage = entry['lang'] as String?;

  return MediaTrack(
    id: id,
    kind: kind,
    title: _nonEmpty(entry['title'] as String?),
    // Containers carry 639-1 or 639-2; normalise so the rest of the app only
    // ever sees 639-3.
    languageCode: rawLanguage == null ? null : toIso6393(rawLanguage),
    codec: codec,
    isDefault: entry['default'] == true,
    isForced: entry['forced'] == true,
    isImageBased: kind == MediaTrackKind.subtitle &&
        codec != null &&
        imageSubtitleCodecs.contains(codec.toLowerCase()),
    channelCount: (entry['demux-channel-count'] as num?)?.toInt(),
    width: (entry['demux-w'] as num?)?.toInt(),
    height: (entry['demux-h'] as num?)?.toInt(),
  );
}

String? _nonEmpty(String? value) =>
    value == null || value.isEmpty ? null : value;

/// The id of the currently selected track of [kind], or null if none is.
int? selectedTrackId(String json, MediaTrackKind kind) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return null;
  }
  if (decoded is! List) return null;

  final typeName = switch (kind) {
    MediaTrackKind.video => 'video',
    MediaTrackKind.audio => 'audio',
    MediaTrackKind.subtitle => 'sub',
  };

  for (final entry in decoded) {
    if (entry is! Map) continue;
    if (entry['type'] != typeName || entry['selected'] != true) continue;
    return (entry['id'] as num?)?.toInt();
  }
  return null;
}
