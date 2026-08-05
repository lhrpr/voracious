/// The headless state machine behind the player screen.
///
/// Everything the study modes do — deciding which subtitle lines are on screen,
/// pausing at the right moment, revealing one track at a time, walking through
/// a file line by line — happens here, driven only by position updates and
/// user intents. The UI renders [StudySessionSnapshot] and forwards key
/// presses; it holds no logic of its own, which is what makes the modes
/// testable without a screen or a running engine.
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../cues/cue_index.dart';
import '../player/media_player.dart';
import 'subtitle_mode.dart';

/// The playback operations a study session needs.
///
/// Deliberately smaller than [MediaPlayer]: a session drives playback, it does
/// not manage it, and the narrow surface keeps the modes testable against a
/// handful of fake methods.
abstract interface class StudyPlaybackController {
  Duration get position;
  bool get isPlaying;

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
}

/// Adapts a full [MediaPlayer] to [StudyPlaybackController].
class MediaPlayerStudyController implements StudyPlaybackController {
  MediaPlayerStudyController(this.player);

  final MediaPlayer player;

  @override
  Duration get position => player.state.position;

  @override
  bool get isPlaying => player.state.isPlaying;

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);
}

/// One analysed subtitle track available to a session.
@immutable
class StudyTrack {
  const StudyTrack({
    required this.id,
    required this.cues,
    this.languageCode,
    this.displayName = '',
  });

  final String id;
  final CueIndex cues;
  final String? languageCode;
  final String displayName;

  @override
  String toString() => 'StudyTrack($id, $languageCode, ${cues.length} cues)';
}

/// What one track is showing right now.
@immutable
class DisplayedTrack {
  const DisplayedTrack({
    required this.track,
    required this.cue,
    required this.isHidden,
  });

  final StudyTrack track;

  /// The line at the current display time, or null in a gap.
  final StudyCue? cue;

  /// True when the mode is withholding this track from the user.
  final bool isHidden;

  bool get hasCue => cue != null;

  @override
  String toString() =>
      'DisplayedTrack(${track.id}, ${cue?.id ?? '-'}, hidden: $isHidden)';
}

/// An A-B loop over a stretch of the file.
@immutable
class AbLoop {
  const AbLoop({required this.begin, required this.end});

  final Duration begin;
  final Duration end;

  bool get isValid => end > begin;

  Duration get duration => end - begin;

  @override
  bool operator ==(Object other) =>
      other is AbLoop && other.begin == begin && other.end == end;

  @override
  int get hashCode => Object.hash(begin, end);

  @override
  String toString() =>
      'AbLoop(${begin.inMilliseconds}-${end.inMilliseconds}ms)';
}

/// Tuning for the study modes.
@immutable
class StudySettings {
  const StudySettings({
    this.pauseLead = const Duration(milliseconds: 300),
    this.seekNudge = const Duration(milliseconds: 50),
    this.noSubtitleSeekStep = const Duration(seconds: 3),
    this.loopPadding = const Duration(milliseconds: 250),
  });

  /// How far before a line's end listening mode pauses. Pausing exactly on the
  /// end tends to clip the last mora.
  final Duration pauseLead;

  /// Added when seeking to a line's start. Engines seek to the nearest
  /// keyframe and floating-point timestamps round both ways; without this,
  /// "replay this line" occasionally lands just before it and immediately
  /// re-triggers the auto-pause.
  final Duration seekNudge;

  /// How far the previous/next controls jump when there are no subtitles to
  /// navigate by.
  final Duration noSubtitleSeekStep;

  /// Extra time either side when building a loop from a subtitle line.
  final Duration loopPadding;
}

/// An immutable view of the session, for rendering.
@immutable
class StudySessionSnapshot {
  const StudySessionSnapshot({
    required this.mode,
    required this.displayTime,
    required this.tracks,
    required this.revealedTrackCount,
    required this.isFrozen,
    this.loop,
  });

  final SubtitleMode mode;

  /// The time the displayed lines correspond to. This lags the real position
  /// while an auto-pause is pending, which is the point: the line that
  /// triggered the pause stays on screen instead of vanishing as playback
  /// crosses its end.
  final Duration displayTime;

  final List<DisplayedTrack> tracks;

  /// How many tracks the user has revealed in a progressive mode.
  final int revealedTrackCount;

  /// True while the session is holding the display still after an auto-pause.
  final bool isFrozen;

  final AbLoop? loop;

  /// The line the export and replay actions act on: the first ordered track's
  /// current line.
  StudyCue? get primaryCue => tracks.isEmpty ? null : tracks.first.cue;

  /// Tracks the user can currently see.
  List<DisplayedTrack> get visibleTracks =>
      tracks.where((t) => !t.isHidden).toList();

  bool get hasAnythingToShow => tracks.any((t) => t.hasCue && !t.isHidden);

  @override
  String toString() => 'StudySessionSnapshot(${mode.wireName}, '
      '${displayTime.inMilliseconds}ms, revealed: $revealedTrackCount)';
}

/// Drives the study modes.
class StudySession {
  StudySession({
    required StudyPlaybackController playback,
    List<StudyTrack> tracks = const [],
    SubtitleMode mode = SubtitleMode.manual,
    this.settings = const StudySettings(),
  })  : _playback = playback,
        _tracks = List.of(tracks),
        _mode = mode {
    _resetModeState();
    _recomputeDisplay(Duration.zero);
  }

  final StudyPlaybackController _playback;
  final StudySettings settings;

  final _controller = StreamController<StudySessionSnapshot>.broadcast();

  List<StudyTrack> _tracks;
  SubtitleMode _mode;

  Duration _displayTime = Duration.zero;
  List<DisplayedTrack> _displayed = const [];

  /// Last position seen, used to detect crossing a trigger point. Null after a
  /// seek, when "crossing" is meaningless.
  Duration? _lastPosition;

  /// While set, position updates do not move the display or re-trigger an
  /// auto-pause. Cleared when the user continues or seeks.
  bool _frozen = false;

  int _revealedTrackCount = 0;
  final Set<int> _hiddenTrackIndices = {};

  AbLoop? _loop;

  /// Snapshots, emitted whenever anything visible changes.
  Stream<StudySessionSnapshot> get snapshots => _controller.stream;

  StudySessionSnapshot get snapshot => StudySessionSnapshot(
        mode: _mode,
        displayTime: _displayTime,
        tracks: _displayed,
        revealedTrackCount: _revealedTrackCount,
        isFrozen: _frozen,
        loop: _loop,
      );

  SubtitleMode get mode => _mode;

  List<StudyTrack> get tracks => List.unmodifiable(_tracks);

  AbLoop? get loop => _loop;

  /// Replaces the track list, keeping the current display time.
  ///
  /// Called as tracks finish loading, which happens after playback has already
  /// started.
  void setTracks(List<StudyTrack> tracks) {
    _tracks = List.of(tracks);
    _hiddenTrackIndices.removeWhere((index) => index >= _tracks.length);
    if (_revealedTrackCount > _tracks.length) {
      _revealedTrackCount = _tracks.length;
    }
    _recomputeDisplay(_displayTime);
    _emit();
  }

  /// Switches mode, resetting whatever reveal state the old mode held.
  void setMode(SubtitleMode mode) {
    if (mode == _mode) return;
    _mode = mode;
    _resetModeState();
    _frozen = false;
    _recomputeDisplay(_displayTime);
    _emit();
  }

  /// Feeds a position update from the engine.
  ///
  /// This is where auto-pause lives. [isPlaying] must reflect the engine, not
  /// the intent: pausing on a position update that arrives while seeking would
  /// fire on every jump.
  Future<void> onPositionChanged(
    Duration position, {
    required bool isPlaying,
  }) async {
    final activeLoop = _loop;
    if (activeLoop != null &&
        activeLoop.isValid &&
        position >= activeLoop.end) {
      _frozen = false;
      _lastPosition = null;
      await _playback.seek(activeLoop.begin);
      return;
    }

    if (_frozen) return;

    final updated = _computeDisplay(position);
    var moveDisplay = true;

    if (isPlaying) {
      switch (_mode) {
        case SubtitleMode.manual:
        case SubtitleMode.quickCheck:
          break;

        case SubtitleMode.listen:
          // Pause just before the current line ends, so the user can decide
          // whether they understood it before the next line arrives.
          final current = _displayed.firstOrNull?.cue;
          final previous = _lastPosition;
          if (current != null && previous != null) {
            final trigger = current.end - settings.pauseLead;
            if (previous < trigger && position >= trigger) {
              _frozen = true;
              // Hold the display on the line that triggered the pause.
              moveDisplay = false;
              await _playback.pause();
            }
          }

        case SubtitleMode.read:
          // Pause as each new line starts, before it has been spoken.
          final current = _displayed.firstOrNull?.cue;
          final next = updated.firstOrNull?.cue;
          if (next != null &&
              !identical(current, next) &&
              current?.id != next.id) {
            _frozen = true;
            await _playback.pause();
          }
      }
    }

    _lastPosition = position;

    if (!moveDisplay) {
      _emit();
      return;
    }

    // Moving to a new line re-hides the tracks in a progressive mode.
    if (_mode.revealsProgressively && _displayed.isNotEmpty) {
      final previousCue = _displayed.first.cue;
      final nextCue = updated.first.cue;
      if (previousCue?.id != nextCue?.id) _revealedTrackCount = 0;
    }

    _displayTime = position;
    _displayed = _applyHiding(updated);
    _emit();
  }

  /// Tells the session that a seek has begun, so it stops holding the display
  /// and does not treat the jump as crossing a trigger point.
  void onSeekStarted() {
    _frozen = false;
    _lastPosition = null;
  }

  /// The primary action, bound to the down arrow.
  ///
  /// What it does depends on the mode: resume, reveal one more track, or
  /// resume after the last one has been revealed.
  Future<void> continueStudy() async {
    switch (_mode) {
      case SubtitleMode.manual:
        await _playback.play();

      case SubtitleMode.quickCheck:
      case SubtitleMode.listen:
        final revealable = _displayed.length;
        if (_revealedTrackCount >= revealable) {
          _frozen = false;
          _revealedTrackCount = revealable;
          await _playback.play();
        } else {
          _revealedTrackCount++;
          _displayed = _applyHiding(_displayed);
          _emit();
          // Quick Check reveals on demand while playing, so revealing has to
          // stop the video too — otherwise the line is gone before it is read.
          if (_mode == SubtitleMode.quickCheck) {
            _frozen = true;
            await _playback.pause();
          }
        }

      case SubtitleMode.read:
        _frozen = false;
        await _playback.play();
    }
  }

  /// Replays the current line from its start.
  Future<void> replayCurrentCue() async {
    final cue = _displayed.firstOrNull?.cue;
    if (cue == null) return;
    _frozen = false;
    _lastPosition = null;
    await _playback.seek(cue.begin + settings.seekNudge);
    await _playback.play();
  }

  /// Jumps to the previous subtitle line, or back a few seconds when there are
  /// none.
  Future<void> goToPreviousCue() async {
    final track = _primaryTrack;
    if (track == null) {
      final target = _playback.position - settings.noSubtitleSeekStep;
      await _seekAndUnfreeze(target.isNegative ? Duration.zero : target);
      return;
    }

    final cue = track.cues.previousCue(_displayTime);
    if (cue == null) return;
    await _seekAndUnfreeze(cue.begin + settings.seekNudge);
  }

  /// Jumps to the next subtitle line, or forward a few seconds when there are
  /// none.
  Future<void> goToNextCue() async {
    final track = _primaryTrack;
    if (track == null) {
      await _seekAndUnfreeze(_playback.position + settings.noSubtitleSeekStep);
      return;
    }

    final cue = track.cues.nextCue(_displayTime);
    if (cue == null) return;
    await _seekAndUnfreeze(cue.begin + settings.seekNudge);

    // Reading practice pauses at the start of a line; jumping to one skips
    // past the moment that would have triggered it, so pause here instead.
    if (_mode == SubtitleMode.read) {
      _frozen = true;
      await _playback.pause();
    }
  }

  /// Play/pause, which also releases a held display.
  Future<void> togglePause() async {
    _frozen = false;
    if (_playback.isPlaying) {
      await _playback.pause();
    } else {
      await _playback.play();
    }
  }

  /// Shows or hides one track by index. Manual mode only; the progressive
  /// modes own their own reveal state.
  void toggleTrackHidden(int trackIndex) {
    if (_mode != SubtitleMode.manual) return;
    if (trackIndex < 0 || trackIndex >= _tracks.length) return;

    if (!_hiddenTrackIndices.remove(trackIndex)) {
      _hiddenTrackIndices.add(trackIndex);
    }
    _displayed = _applyHiding(_displayed);
    _emit();
  }

  /// Reveals every track at once, whatever the mode.
  void revealAll() {
    _revealedTrackCount = _displayed.length;
    _hiddenTrackIndices.clear();
    _displayed = _applyHiding(_displayed);
    _emit();
  }

  /// Sets an A-B loop over the current line, padded by
  /// [StudySettings.loopPadding].
  void loopCurrentCue() {
    final cue = _displayed.firstOrNull?.cue;
    if (cue == null) return;
    final begin = cue.begin - settings.loopPadding;
    setLoop(AbLoop(
      begin: begin.isNegative ? Duration.zero : begin,
      end: cue.end + settings.loopPadding,
    ));
  }

  void setLoop(AbLoop? loop) {
    _loop = loop != null && loop.isValid ? loop : null;
    _emit();
  }

  void clearLoop() => setLoop(null);

  Future<void> dispose() => _controller.close();

  StudyTrack? get _primaryTrack =>
      _tracks.firstWhereOrNull((track) => track.cues.isNotEmpty);

  Future<void> _seekAndUnfreeze(Duration position) async {
    _frozen = false;
    _lastPosition = null;
    await _playback.seek(position);
  }

  void _resetModeState() {
    _revealedTrackCount = 0;
    _hiddenTrackIndices.clear();
  }

  void _recomputeDisplay(Duration time) {
    _displayTime = time;
    _displayed = _applyHiding(_computeDisplay(time));
  }

  List<DisplayedTrack> _computeDisplay(Duration time) => [
        for (final track in _tracks)
          DisplayedTrack(
            track: track,
            cue: track.cues.cueAt(time),
            isHidden: false,
          ),
      ];

  /// Applies whichever hiding rule the current mode uses.
  List<DisplayedTrack> _applyHiding(List<DisplayedTrack> tracks) => [
        for (var index = 0; index < tracks.length; index++)
          DisplayedTrack(
            track: tracks[index].track,
            cue: tracks[index].cue,
            isHidden: switch (_mode) {
              SubtitleMode.manual => _hiddenTrackIndices.contains(index),
              SubtitleMode.quickCheck ||
              SubtitleMode.listen =>
                index >= _revealedTrackCount,
              SubtitleMode.read => false,
            },
          ),
      ];

  void _emit() {
    if (!_controller.isClosed) _controller.add(snapshot);
  }
}
