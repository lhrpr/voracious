/// A time-indexed, immutable set of study cues.
///
/// This is the data structure the player queries on every frame ("what should
/// be on screen now?") and every keypress ("what is the previous subtitle?"),
/// so lookups are binary searches rather than scans. Nothing here is
/// asynchronous or platform-bound.
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../text/annotated_text.dart';
import '../util/uid.dart';

/// One subtitle line, analysed and ready to study.
@immutable
class StudyCue {
  StudyCue({
    required this.begin,
    required this.end,
    required this.text,
    String? id,
  }) : id = id ?? generateUid('cue');

  /// Stable within a process; used as a widget key and to address a cue when
  /// annotations are edited.
  final String id;

  final Duration begin;
  final Duration end;
  final AnnotatedText text;

  Duration get duration => end - begin;

  bool contains(Duration time) => time >= begin && time < end;

  StudyCue withText(AnnotatedText newText) => StudyCue(
        id: id,
        begin: begin,
        end: end,
        text: newText,
      );

  StudyCue shifted(Duration offset) {
    final newBegin = begin + offset;
    final newEnd = end + offset;
    return StudyCue(
      id: id,
      begin: newBegin.isNegative ? Duration.zero : newBegin,
      end: newEnd.isNegative ? Duration.zero : newEnd,
      text: text,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'beginMs': begin.inMilliseconds,
        'endMs': end.inMilliseconds,
        'text': text.toJson(),
      };

  static StudyCue fromJson(Map<String, Object?> json) => StudyCue(
        id: json['id'] as String?,
        begin: Duration(milliseconds: (json['beginMs']! as num).toInt()),
        end: Duration(milliseconds: (json['endMs']! as num).toInt()),
        text: AnnotatedText.fromJson(json['text']! as Map<String, Object?>),
      );

  @override
  String toString() =>
      'StudyCue($id, ${begin.inMilliseconds}-${end.inMilliseconds}ms)';
}

/// An immutable, time-sorted collection of [StudyCue]s with fast time lookup.
class CueIndex {
  CueIndex._(this._cues, this._longestCue) : cues = UnmodifiableListView(_cues);

  /// Builds an index from [cues], sorting them by start time.
  factory CueIndex(Iterable<StudyCue> cues) {
    final sorted = List<StudyCue>.of(cues)
      ..sort((a, b) => a.begin.compareTo(b.begin));
    var longest = Duration.zero;
    for (final cue in sorted) {
      if (cue.duration > longest) longest = cue.duration;
    }
    return CueIndex._(sorted, longest);
  }

  static final CueIndex empty = CueIndex(const []);

  final List<StudyCue> _cues;

  /// The longest cue in the track. Bounds how far back an overlap search has
  /// to look, which is what keeps [activeCues] exact without an interval tree.
  final Duration _longestCue;

  /// Cues in start-time order.
  final List<StudyCue> cues;

  int get length => _cues.length;
  bool get isEmpty => _cues.isEmpty;
  bool get isNotEmpty => _cues.isNotEmpty;

  StudyCue operator [](int index) => _cues[index];

  /// End of the last cue, or zero for an empty index.
  Duration get lastEnd =>
      _cues.fold(Duration.zero, (max, c) => c.end > max ? c.end : max);

  /// Index of the last cue starting at or before [time], or null if every cue
  /// starts later.
  int? lastStartingAtOrBefore(Duration time) {
    var low = 0;
    var high = _cues.length - 1;
    int? found;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (_cues[mid].begin <= time) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found;
  }

  /// Index of the first cue starting strictly after [time], or null if none
  /// does.
  int? firstStartingAfter(Duration time) {
    var low = 0;
    var high = _cues.length - 1;
    int? found;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (_cues[mid].begin <= time) {
        low = mid + 1;
      } else {
        found = mid;
        high = mid - 1;
      }
    }
    return found;
  }

  /// Every cue whose range covers [time], in start-time order.
  ///
  /// Overlapping cues are normal in ASS tracks (a sign over dialogue, or two
  /// speakers), so this returns all of them rather than just one.
  List<StudyCue> activeCues(Duration time) {
    final start = lastStartingAtOrBefore(time);
    if (start == null) return const [];

    final result = <StudyCue>[];
    // Any cue covering `time` must start within one longest-cue window of it.
    final earliest = time - _longestCue;
    for (var i = start; i >= 0; i--) {
      final cue = _cues[i];
      if (cue.begin < earliest) break;
      if (cue.contains(time)) result.add(cue);
    }
    return result.reversed.toList();
  }

  /// The cue to treat as current at [time]: the latest-starting cue covering
  /// it, or null when [time] falls in a gap.
  StudyCue? cueAt(Duration time) {
    final active = activeCues(time);
    return active.isEmpty ? null : active.last;
  }

  /// The cue a "previous subtitle" jump should land on from [time].
  ///
  /// Inside a cue, that is the one before it; in a gap, it is the cue that just
  /// ended — which is what makes repeated presses walk backwards one line at a
  /// time from anywhere in the track.
  StudyCue? previousCue(Duration time) {
    final current = cueAt(time);
    if (current != null) {
      final index = _cues.indexOf(current);
      return index > 0 ? _cues[index - 1] : null;
    }
    final index = lastStartingAtOrBefore(time);
    return index == null ? null : _cues[index];
  }

  /// The first cue starting after [time], or null at the end of the track.
  StudyCue? nextCue(Duration time) {
    final index = firstStartingAfter(time);
    return index == null ? null : _cues[index];
  }

  StudyCue? byId(String id) => _cues.firstWhereOrNull((c) => c.id == id);

  /// Returns a copy with the cue [id]'s annotated text replaced.
  CueIndex updateText(String id, AnnotatedText text) => CueIndex(
        _cues.map((c) => c.id == id ? c.withText(text) : c),
      );

  /// Returns a copy with every cue's timing moved by [offset], for subtitle
  /// sync correction.
  CueIndex shifted(Duration offset) =>
      CueIndex(_cues.map((c) => c.shifted(offset)));

  @override
  String toString() => 'CueIndex(${_cues.length} cues)';
}
