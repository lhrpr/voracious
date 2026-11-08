/// Text subtitle tracks embedded in Matroska (MKV/WebM) files.
///
/// Most downloaded TV and anime ships its subtitles inside the MKV rather
/// than beside it. This reads them out without ffmpeg: the track list comes
/// from the file header, and each text track is rebuilt as an ordinary SRT,
/// ASS or WebVTT file, which then goes through the same loader as a sidecar
/// file — charset handling, ASS style filtering and language detection all
/// included.
///
/// Image-based tracks (PGS, VobSub, DVB) are listed but can't be extracted:
/// they are pictures, not text.
library;

import 'dart:typed_data';

import '../language/language_table.dart';
import '../subtitles/subtitle_format.dart';
import 'ebml.dart';

/// One subtitle track declared in a Matroska file.
class EmbeddedSubtitleTrack {
  const EmbeddedSubtitleTrack({
    required this.number,
    required this.codecId,
    this.languageCode,
    this.name,
    this.isDefault = false,
    this.isForced = false,
    this.isHearingImpaired = false,
  });

  /// Matroska track number. Unique within the file.
  final int number;

  /// Matroska codec ID, e.g. `S_TEXT/ASS` or `S_HDMV/PGS`.
  final String codecId;

  /// ISO 639-3 code, or null when the file didn't say (or said "und").
  final String? languageCode;

  /// Track title, e.g. "Signs & Songs" or "Full Subtitles".
  final String? name;

  final bool isDefault;
  final bool isForced;
  final bool isHearingImpaired;

  /// The text format this track can be rebuilt as, or null for image-based
  /// and unsupported codecs.
  SubtitleFormat? get format => switch (codecId) {
        'S_TEXT/UTF8' || 'S_TEXT/ASCII' => SubtitleFormat.srt,
        'S_TEXT/ASS' ||
        'S_TEXT/SSA' ||
        'S_ASS' ||
        'S_SSA' =>
          SubtitleFormat.ass,
        'S_TEXT/WEBVTT' => SubtitleFormat.vtt,
        _ => null,
      };

  bool get isText => format != null;

  @override
  String toString() =>
      'EmbeddedSubtitleTrack($number, $codecId, ${languageCode ?? '?'})';
}

/// A text track rebuilt as a standalone subtitle file.
class ExtractedSubtitle {
  const ExtractedSubtitle({
    required this.track,
    required this.contents,
    required this.cueCount,
  });

  final EmbeddedSubtitleTrack track;

  /// The complete file, in [EmbeddedSubtitleTrack.format].
  final String contents;

  final int cueCount;
}

/// Inflates zlib-compressed block data. Core has no `dart:io`, so the host
/// passes one in; without it, compressed tracks are skipped.
typedef ZlibInflater = Uint8List Function(Uint8List compressed);

/// Reads subtitle tracks out of a Matroska file.
class MatroskaSubtitleReader {
  MatroskaSubtitleReader(ByteSource source, {this.inflate})
      : _reader = EbmlReader(source);

  final EbmlReader _reader;
  final ZlibInflater? inflate;

  /// Whether [head] (the first few bytes of a file) starts like EBML.
  static bool looksLikeMatroska(Uint8List head) =>
      head.length >= 4 &&
      head[0] == 0x1A &&
      head[1] == 0x45 &&
      head[2] == 0xDF &&
      head[3] == 0xA3;

  _Header? _header;

  /// Every subtitle track the file declares. Reads only the file header, so
  /// it's cheap even on a large file.
  List<EmbeddedSubtitleTrack> subtitleTracks() =>
      [for (final t in _readHeader().tracks) t.track];

  /// Rebuilds the text subtitle tracks, all of them or just [trackNumbers].
  ///
  /// This visits every block header in the file, so it's proportional to the
  /// file's length; hosts run it in the background and cache the result.
  List<ExtractedSubtitle> extract({Set<int>? trackNumbers}) {
    final header = _readHeader();
    final wanted = {
      for (final t in header.tracks)
        if (t.track.isText &&
            (trackNumbers == null || trackNumbers.contains(t.track.number)) &&
            _canDecode(t))
          t.track.number: t,
    };
    if (wanted.isEmpty) return const [];

    final events = {for (final n in wanted.keys) n: <_Event>[]};
    _walkClusters(header, wanted, events);

    return [
      for (final entry in wanted.entries)
        _rebuild(entry.value, events[entry.key]!),
    ];
  }

  bool _canDecode(_TrackInfo info) =>
      info.compression == null ||
      info.compression == _Compression.headerStripping ||
      (info.compression == _Compression.zlib && inflate != null);

  // --------------------------------------------------------------------------
  // Header

  _Header _readHeader() {
    final cached = _header;
    if (cached != null) return cached;

    final ebml = _reader.headerAt(0);
    if (ebml == null || ebml.id != _Id.ebml) {
      throw const FormatException('not a Matroska file');
    }
    final segment = _reader.headerAt(ebml.end);
    if (segment == null || segment.id != _Id.segment) {
      throw const FormatException('no Matroska segment');
    }

    var timestampScale = 1000000;
    final tracks = <_TrackInfo>[];
    int? firstCluster;
    var sawTracks = false;

    final segmentEnd = segment.size == null ? _reader.length : segment.end;
    var offset = segment.dataOffset;
    while (offset < segmentEnd) {
      final child = _reader.headerAt(offset);
      if (child == null) break;

      if (child.id == _Id.info) {
        for (final e in _reader.children(child)) {
          if (e.id == _Id.timestampScale) timestampScale = _reader.readUint(e);
        }
      } else if (child.id == _Id.tracks) {
        sawTracks = true;
        for (final e in _reader.children(child)) {
          if (e.id != _Id.trackEntry) continue;
          final info = _readTrackEntry(e);
          if (info != null) tracks.add(info);
        }
      } else if (child.id == _Id.cluster) {
        firstCluster ??= child.offset;
        // Tracks come before the first cluster in every file a muxer writes.
        if (sawTracks) break;
      }

      if (child.size == null) {
        // An unknown-size element at the top level can only be a cluster;
        // nothing after it can be skipped to cheaply.
        break;
      }
      offset = child.end;
    }

    return _header = _Header(
      timestampScale: timestampScale,
      tracks: tracks,
      segmentStart: segment.dataOffset,
      segmentEnd: segmentEnd,
      firstCluster: firstCluster,
    );
  }

  _TrackInfo? _readTrackEntry(EbmlHeader entry) {
    int? number;
    int? type;
    String? codecId;
    Uint8List? codecPrivate;
    String? language;
    String? languageBcp47;
    String? name;
    var isDefault = true; // Matroska's default for FlagDefault.
    var isForced = false;
    var isHearingImpaired = false;
    _Compression? compression;
    Uint8List? strippedHeader;

    for (final e in _reader.children(entry)) {
      switch (e.id) {
        case _Id.trackNumber:
          number = _reader.readUint(e);
        case _Id.trackType:
          type = _reader.readUint(e);
        case _Id.codecId:
          codecId = _reader.readString(e);
        case _Id.codecPrivate:
          codecPrivate = Uint8List.fromList(_reader.payload(e));
        case _Id.language:
          language = _reader.readString(e);
        case _Id.languageBcp47:
          languageBcp47 = _reader.readString(e);
        case _Id.name:
          name = _reader.readString(e);
        case _Id.flagDefault:
          isDefault = _reader.readUint(e) != 0;
        case _Id.flagForced:
          isForced = _reader.readUint(e) != 0;
        case _Id.flagHearingImpaired:
          isHearingImpaired = _reader.readUint(e) != 0;
        case _Id.contentEncodings:
          (compression, strippedHeader) = _readEncodings(e);
      }
    }

    if (number == null || type != _subtitleTrackType || codecId == null) {
      return null;
    }

    final title = name?.trim();
    final lowerTitle = title?.toLowerCase() ?? '';
    return _TrackInfo(
      track: EmbeddedSubtitleTrack(
        number: number,
        codecId: codecId,
        languageCode: _normaliseLanguage(languageBcp47, language),
        name: title == null || title.isEmpty ? null : title,
        isDefault: isDefault,
        // Plenty of files only say so in the title.
        isForced: isForced || lowerTitle.contains('forced'),
        isHearingImpaired: isHearingImpaired ||
            RegExp(r'\b(sdh|cc)\b|hearing impaired').hasMatch(lowerTitle),
      ),
      codecPrivate: codecPrivate,
      compression: compression,
      strippedHeader: strippedHeader,
    );
  }

  /// Only compression is supported: encrypted tracks are not something a
  /// subtitle track ever is in practice.
  (_Compression?, Uint8List?) _readEncodings(EbmlHeader encodings) {
    for (final encoding in _reader.children(encodings)) {
      if (encoding.id != _Id.contentEncoding) continue;
      for (final e in _reader.children(encoding)) {
        if (e.id != _Id.contentCompression) continue;
        var algorithm = 0; // zlib is the default.
        Uint8List? settings;
        for (final c in _reader.children(e)) {
          if (c.id == _Id.contentCompAlgo) algorithm = _reader.readUint(c);
          if (c.id == _Id.contentCompSettings) {
            settings = Uint8List.fromList(_reader.payload(c));
          }
        }
        return switch (algorithm) {
          0 => (_Compression.zlib, null),
          3 => (_Compression.headerStripping, settings),
          _ => (_Compression.unsupported, null),
        };
      }
    }
    return (null, null);
  }

  // --------------------------------------------------------------------------
  // Clusters

  void _walkClusters(
    _Header header,
    Map<int, _TrackInfo> wanted,
    Map<int, List<_Event>> events,
  ) {
    var offset = header.firstCluster ?? header.segmentStart;
    while (offset < header.segmentEnd) {
      final element = _reader.headerAt(offset);
      if (element == null) break;

      if (element.id == _Id.cluster) {
        offset = _walkCluster(element, header, wanted, events);
        continue;
      }
      if (element.size == null) break;
      offset = element.end;
    }
  }

  /// Walks one cluster and returns the offset just past it. An unknown-size
  /// cluster ends where the next top-level element starts.
  int _walkCluster(
    EbmlHeader cluster,
    _Header header,
    Map<int, _TrackInfo> wanted,
    Map<int, List<_Event>> events,
  ) {
    final end = cluster.size == null ? header.segmentEnd : cluster.end;
    var clusterTimestamp = 0;
    var offset = cluster.dataOffset;

    while (offset < end) {
      final child = _reader.headerAt(offset);
      if (child == null) return _reader.length;
      if (cluster.size == null && _topLevelIds.contains(child.id)) {
        return child.offset;
      }
      if (child.size == null) return _reader.length;

      switch (child.id) {
        case _Id.timestamp:
          clusterTimestamp = _reader.readUint(child);
        case _Id.simpleBlock:
          _readBlock(child, null, clusterTimestamp, header, wanted, events);
        case _Id.blockGroup:
          _readBlockGroup(child, clusterTimestamp, header, wanted, events);
      }
      offset = child.end;
    }
    return end;
  }

  void _readBlockGroup(
    EbmlHeader group,
    int clusterTimestamp,
    _Header header,
    Map<int, _TrackInfo> wanted,
    Map<int, List<_Event>> events,
  ) {
    EbmlHeader? block;
    int? duration;
    for (final e in _reader.children(group)) {
      if (e.id == _Id.block) block = e;
      if (e.id == _Id.blockDuration) duration = _reader.readUint(e);
    }
    if (block != null) {
      _readBlock(block, duration, clusterTimestamp, header, wanted, events);
    }
  }

  void _readBlock(
    EbmlHeader block,
    int? duration,
    int clusterTimestamp,
    _Header header,
    Map<int, _TrackInfo> wanted,
    Map<int, List<_Event>> events,
  ) {
    // Peek at the track number before reading the payload: nearly every block
    // in the file is video or audio, and those are skipped unread.
    final head = _reader.bytesAt(block.dataOffset, 12);
    final (trackNumber, trackLength) = readVint(head);
    final track = wanted[trackNumber];
    if (track == null) return;

    final payload = _reader.payload(block);
    if (payload.length < trackLength + 3) return;
    final relative = ByteData.sublistView(payload).getInt16(trackLength);
    final flags = payload[trackLength + 2];
    // Laced subtitle blocks don't occur in practice; skip rather than guess.
    if ((flags >> 1) & 0x03 != 0) return;

    var data = Uint8List.sublistView(payload, trackLength + 3);
    switch (track.compression) {
      case _Compression.zlib:
        data = inflate!(Uint8List.fromList(data));
      case _Compression.headerStripping:
        data = Uint8List.fromList([...?track.strippedHeader, ...data]);
      case _Compression.unsupported || null:
        break;
    }

    final scale = header.timestampScale;
    final startNs = (clusterTimestamp + relative) * scale;
    events[trackNumber]!.add(
      _Event(
        start: Duration(microseconds: startNs ~/ 1000),
        duration: duration == null
            ? null
            : Duration(microseconds: duration * scale ~/ 1000),
        text: decodeUtf8Lenient(data),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Rebuilding

  ExtractedSubtitle _rebuild(_TrackInfo info, List<_Event> events) {
    events.sort((a, b) => a.start.compareTo(b.start));
    final timed = _withEnds(events);
    final contents = switch (info.track.format!) {
      SubtitleFormat.srt => _toSrt(timed),
      SubtitleFormat.vtt => _toVtt(timed),
      SubtitleFormat.ass => _toAss(info, timed),
    };
    return ExtractedSubtitle(
      track: info.track,
      contents: contents,
      cueCount: timed.length,
    );
  }

  /// Fills in missing durations: up to the next event, at most five seconds.
  static List<(_Event, Duration)> _withEnds(List<_Event> events) {
    const fallback = Duration(seconds: 5);
    return [
      for (var i = 0; i < events.length; i++)
        (
          events[i],
          events[i].duration != null
              ? events[i].start + events[i].duration!
              : () {
                  final cap = events[i].start + fallback;
                  if (i + 1 >= events.length) return cap;
                  final next = events[i + 1].start;
                  return next > events[i].start && next < cap ? next : cap;
                }(),
        ),
    ];
  }

  static String _toSrt(List<(_Event, Duration)> events) {
    final out = StringBuffer();
    var n = 1;
    for (final (event, end) in events) {
      final text = event.text.trim();
      if (text.isEmpty) continue;
      out
        ..writeln(n++)
        ..writeln('${_srtTime(event.start)} --> ${_srtTime(end)}')
        ..writeln(text)
        ..writeln();
    }
    return out.toString();
  }

  static String _toVtt(List<(_Event, Duration)> events) {
    final out = StringBuffer()
      ..writeln('WEBVTT')
      ..writeln();
    for (final (event, end) in events) {
      final text = event.text.trim();
      if (text.isEmpty) continue;
      out
        ..writeln('${_vttTime(event.start)} --> ${_vttTime(end)}')
        ..writeln(text)
        ..writeln();
    }
    return out.toString();
  }

  /// ASS blocks carry every Dialogue field except the times, led by a read
  /// order: `ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect,
  /// Text`. The script header (styles and all) is the track's CodecPrivate.
  static String _toAss(_TrackInfo info, List<(_Event, Duration)> events) {
    final out = StringBuffer();
    final private = info.codecPrivate == null
        ? ''
        : decodeUtf8Lenient(info.codecPrivate!).replaceAll('\r\n', '\n');

    var script = private.trimRight();
    if (script.isEmpty) script = '[Script Info]\nScriptType: v4.00+';
    out.writeln(script);
    if (!script.contains('[Events]')) {
      out
        ..writeln()
        ..writeln('[Events]')
        ..writeln('Format: Layer, Start, End, Style, Name, MarginL, MarginR, '
            'MarginV, Effect, Text');
    }

    final lines = <(int, Duration, String)>[];
    for (final (event, end) in events) {
      final fields = _splitFields(event.text, 9);
      if (fields.length < 9) continue;
      final readOrder = int.tryParse(fields[0].trim()) ?? 0;
      lines.add((
        readOrder,
        event.start,
        'Dialogue: ${fields[1]},${_assTime(event.start)},${_assTime(end)},'
            '${fields.sublist(2).join(',')}',
      ));
    }
    // Time order for readers, read order to break ties as the muxer intended.
    lines.sort((a, b) {
      final byTime = a.$2.compareTo(b.$2);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
    for (final line in lines) {
      out.writeln(line.$3);
    }
    return out.toString();
  }

  /// Splits on the first `count - 1` commas; the last field (the dialogue
  /// text) keeps any commas of its own.
  static List<String> _splitFields(String line, int count) {
    final fields = <String>[];
    var start = 0;
    while (fields.length < count - 1) {
      final comma = line.indexOf(',', start);
      if (comma < 0) break;
      fields.add(line.substring(start, comma));
      start = comma + 1;
    }
    fields.add(line.substring(start).replaceAll(RegExp(r'[\r\n]+$'), ''));
    return fields;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _three(int n) => n.toString().padLeft(3, '0');

  static String _srtTime(Duration d) =>
      '${_two(d.inHours)}:${_two(d.inMinutes % 60)}:${_two(d.inSeconds % 60)},'
      '${_three(d.inMilliseconds % 1000)}';

  static String _vttTime(Duration d) =>
      '${_two(d.inHours)}:${_two(d.inMinutes % 60)}:${_two(d.inSeconds % 60)}.'
      '${_three(d.inMilliseconds % 1000)}';

  static String _assTime(Duration d) =>
      '${d.inHours}:${_two(d.inMinutes % 60)}:${_two(d.inSeconds % 60)}.'
      '${_two((d.inMilliseconds % 1000) ~/ 10)}';

  /// Matroska uses ISO 639-2, which includes bibliographic codes ("fre",
  /// "ger") the language table doesn't know; BCP 47 wins when present.
  static String? _normaliseLanguage(String? bcp47, String? iso6392) {
    String? resolve(String? raw) {
      if (raw == null) return null;
      final primary = raw.split(RegExp('[-_]')).first.trim().toLowerCase();
      if (primary.isEmpty || primary == 'und' || primary == 'mul') return null;
      return toIso6393(_bibliographic[primary] ?? primary);
    }

    return resolve(bcp47) ?? resolve(iso6392);
  }

  static const _bibliographic = {
    'alb': 'sqi',
    'arm': 'hye',
    'baq': 'eus',
    'bur': 'mya',
    'chi': 'zho',
    'cze': 'ces',
    'dut': 'nld',
    'fre': 'fra',
    'geo': 'kat',
    'ger': 'deu',
    'gre': 'ell',
    'ice': 'isl',
    'mac': 'mkd',
    'mao': 'mri',
    'may': 'msa',
    'per': 'fas',
    'rum': 'ron',
    'slo': 'slk',
    'tib': 'bod',
    'wel': 'cym',
  };
}

const _subtitleTrackType = 0x11;

/// Element IDs, from the Matroska specification.
abstract final class _Id {
  static const ebml = 0x1A45DFA3;
  static const segment = 0x18538067;
  static const seekHead = 0x114D9B74;
  static const info = 0x1549A966;
  static const timestampScale = 0x2AD7B1;
  static const tracks = 0x1654AE6B;
  static const trackEntry = 0xAE;
  static const trackNumber = 0xD7;
  static const trackType = 0x83;
  static const codecId = 0x86;
  static const codecPrivate = 0x63A2;
  static const language = 0x22B59C;
  static const languageBcp47 = 0x22B59D;
  static const name = 0x536E;
  static const flagDefault = 0x88;
  static const flagForced = 0x55AA;
  static const flagHearingImpaired = 0x55AB;
  static const contentEncodings = 0x6D80;
  static const contentEncoding = 0x6240;
  static const contentCompression = 0x5034;
  static const contentCompAlgo = 0x4254;
  static const contentCompSettings = 0x4255;
  static const cluster = 0x1F43B675;
  static const timestamp = 0xE7;
  static const simpleBlock = 0xA3;
  static const blockGroup = 0xA0;
  static const block = 0xA1;
  static const blockDuration = 0x9B;
  static const cues = 0x1C53BB6B;
  static const chapters = 0x1043A770;
  static const tags = 0x1254C367;
  static const attachments = 0x1941A469;
}

/// Segment children: seeing one of these inside an unknown-size cluster means
/// the cluster has ended.
const _topLevelIds = {
  _Id.cluster,
  _Id.seekHead,
  _Id.info,
  _Id.tracks,
  _Id.cues,
  _Id.chapters,
  _Id.tags,
  _Id.attachments,
};

enum _Compression { zlib, headerStripping, unsupported }

class _TrackInfo {
  const _TrackInfo({
    required this.track,
    this.codecPrivate,
    this.compression,
    this.strippedHeader,
  });

  final EmbeddedSubtitleTrack track;
  final Uint8List? codecPrivate;
  final _Compression? compression;
  final Uint8List? strippedHeader;
}

class _Header {
  const _Header({
    required this.timestampScale,
    required this.tracks,
    required this.segmentStart,
    required this.segmentEnd,
    required this.firstCluster,
  });

  final int timestampScale;
  final List<_TrackInfo> tracks;
  final int segmentStart;
  final int segmentEnd;
  final int? firstCluster;
}

class _Event {
  const _Event(
      {required this.start, required this.duration, required this.text});

  final Duration start;
  final Duration? duration;
  final String text;
}
