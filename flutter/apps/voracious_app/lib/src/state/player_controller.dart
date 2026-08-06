/// Wires a live libmpv to the headless study session.
///
/// The division of labour is the one the core was designed for: this class
/// owns objects and lifetimes — opening the engine, loading tracks, saving the
/// resume position — and [StudySession] owns every decision about what is on
/// screen and when playback should stop. Nothing here decides study behaviour;
/// when it looks like it might, it is forwarding an intent.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:voracious_core/voracious_core.dart';
import 'package:voracious_core/voracious_core_io.dart';
import 'package:voracious_mpv/voracious_mpv.dart';
import 'package:voracious_video/voracious_video.dart';

/// How far the app is through opening a video.
enum PlayerLoadStage {
  idle,
  startingEngine,
  openingFile,
  loadingSubtitles,
  ready,
  failed
}

class PlayerController extends ChangeNotifier {
  PlayerController({
    required this.video,
    required this.preferences,
    required this.onPositionRecorded,
    this.resumeFrom = Duration.zero,
  });

  final VideoEntry video;
  final Preferences preferences;

  /// Called periodically so the library can show progress and resume later.
  final void Function(Duration position) onPositionRecorded;

  final Duration resumeFrom;

  static const MediaFileSystem _fileSystem = LocalFileSystem();

  MpvPlayer? _player;
  StudySession? _session;
  VideoOutput? _videoOutput;

  StreamSubscription<PlaybackState>? _playbackSubscription;
  StreamSubscription<StudySessionSnapshot>? _sessionSubscription;

  PlayerLoadStage _stage = PlayerLoadStage.idle;
  PlayerLoadStage get stage => _stage;

  String? _error;
  String? get error => _error;

  /// The last state seen, kept only to diff against the next one.
  PlaybackState _lastSeenPlayback = PlaybackState.initial;

  /// Read straight from the objects that own it, never mirrored into a field
  /// fed by a stream. Both of these change synchronously — a keypress calls
  /// into StudySession and returns with the new state already in place — while
  /// stream delivery is a microtask later. A mirrored copy is therefore stale
  /// for exactly as long as it takes to rebuild, which is the frame the user
  /// is looking at. The streams are what say *when* to rebuild; these getters
  /// are what to read.
  PlaybackState get playback => _player?.state ?? _lastSeenPlayback;

  StudySessionSnapshot? get snapshot => _session?.snapshot;

  List<LoadedSubtitleTrack> _tracks = const [];
  List<LoadedSubtitleTrack> get tracks => _tracks;

  /// Description of the libmpv actually loaded. The about screen has to be
  /// able to name it, which is an LGPL obligation.
  String? get engineDescription => _player?.engineDescription;

  /// The texture the engine's frames are being drawn into, or null if this
  /// build has no video output. Playback does not depend on it.
  VideoOutput? get videoOutput => _videoOutput;

  /// Why there is no picture, when there is none. Null in the ordinary case
  /// and also when [videoOutput] exists, so it is only ever a reason.
  String? _videoOutputError;
  String? get videoOutputError => _videoOutputError;

  SubtitleMode get mode => _session?.mode ?? preferences.subtitleMode;

  AbLoop? get loop => _session?.loop;

  Duration _lastRecorded = Duration.zero;

  Future<void> start() async {
    _stage = PlayerLoadStage.startingEngine;
    notifyListeners();

    try {
      final player = await MpvPlayer.create(platform: MpvPlatform.macos);
      _player = player;

      // Before the file is opened, not after. `vo=libmpv` has nowhere to draw
      // until a render context exists, so a file loaded first spends its
      // opening frames with video output stalled.
      await _startVideoOutput(player);

      _session = StudySession(
        playback: MediaPlayerStudyController(player),
        mode: preferences.subtitleMode,
      );
      _sessionSubscription =
          _session!.snapshots.listen((_) => notifyListeners());

      _playbackSubscription = player.states.listen(_onPlaybackState);

      _stage = PlayerLoadStage.openingFile;
      notifyListeners();

      await player.open(video.path, startAt: resumeFrom);
      await player.setSpeed(preferences.playbackSpeed);

      // Subtitles load after playback has started rather than before it: the
      // engine is already showing video while the tracks are being decoded and
      // analysed, and StudySession.setTracks is built for arriving late.
      _stage = PlayerLoadStage.loadingSubtitles;
      notifyListeners();
      await _loadSubtitles();

      _stage = PlayerLoadStage.ready;
      notifyListeners();
    } on Object catch (error) {
      _error = error.toString();
      _stage = PlayerLoadStage.failed;
      notifyListeners();
    }
  }

  /// Attaches the platform renderer to [player].
  ///
  /// Failure here is reported, not thrown. Everything else on this screen —
  /// audio, the subtitle stack, every study mode — works without a picture,
  /// and a build that cannot render video is still worth more than an error
  /// page.
  Future<void> _startVideoOutput(MpvPlayer player) async {
    try {
      _videoOutput = await VideoOutput.create(
        mpvHandle: player.nativeHandle,
        libraryPath: player.libraryPath,
      );
    } on VideoOutputException catch (error) {
      _videoOutputError = error.message;
    }
  }

  Future<void> _loadSubtitles() async {
    final analyzer = TextAnalyzer();
    final loader = SubtitleTrackLoader(
      fileSystem: _fileSystem,
      analyzer: analyzer,
      excludeAssStyles: conventionalNonDialogueStyles,
    );

    final refs = video.subtitleFiles
        .where((ref) => !preferences.hideForcedTracks || ref.isGoodStudyTrack)
        .toList();

    final loaded = <LoadedSubtitleTrack>[];
    for (final ref in refs) {
      try {
        loaded.add(await loader.load(ref));
      } on Object {
        // One unreadable subtitle file should not stop the others, and it is
        // visible in the track list by its absence.
        continue;
      }
    }

    // The order decides which track the study modes take their timing from, so
    // it follows the user's language preferences rather than the scan order.
    _tracks = orderSubtitleTracks(
      loaded.where((track) => track.cues.isNotEmpty),
      languageOf: (track) => track.languageCode,
      idOf: (track) => track.id,
      preferredOrder: preferences.subtitleOrder,
      ignored: preferences.subtitleIgnores.toSet(),
    );

    _session?.setTracks([
      for (final track in _tracks)
        StudyTrack(
          id: track.id,
          cues: track.cues,
          languageCode: track.languageCode,
          displayName: track.languageDisplayName,
        ),
    ]);
  }

  void _onPlaybackState(PlaybackState state) {
    final previous = _lastSeenPlayback;
    _lastSeenPlayback = state;

    // A seek in progress must stand down the auto-pause, or every jump would
    // trip it; the session is told separately from the position update.
    if (state.isSeeking && !previous.isSeeking) _session?.onSeekStarted();

    if (state.position != previous.position) {
      unawaited(_session?.onPositionChanged(
            state.position,
            isPlaying: state.isPlaying,
          ) ??
          Future<void>.value());

      // Persisting on every tick would write continuously; once a second is
      // enough to make resume feel exact.
      if ((state.position - _lastRecorded).abs() >=
          const Duration(seconds: 1)) {
        _lastRecorded = state.position;
        onPositionRecorded(state.position);
      }
    }

    notifyListeners();
  }

  // Intents, forwarded. The session decides what each one means in the current
  // mode; none of this is a decision.

  Future<void> togglePause() async => _session?.togglePause();
  Future<void> continueStudy() async => _session?.continueStudy();
  Future<void> replayCurrentCue() async => _session?.replayCurrentCue();
  Future<void> previousCue() async => _session?.goToPreviousCue();
  Future<void> nextCue() async => _session?.goToNextCue();
  void revealAll() => _session?.revealAll();
  void toggleTrackHidden(int index) => _session?.toggleTrackHidden(index);
  void loopCurrentCue() => _session?.loopCurrentCue();
  void clearLoop() => _session?.clearLoop();

  void setMode(SubtitleMode mode) => _session?.setMode(mode);

  Future<void> seek(Duration position) async => _player?.seek(position);
  Future<void> seekBy(Duration offset) async => _player?.seekBy(offset);
  Future<void> setSpeed(double speed) async => _player?.setSpeed(speed);
  Future<void> setVolume(double volume) async => _player?.setVolume(volume);
  Future<void> setMuted(bool muted) async => _player?.setMuted(muted);
  Future<void> setAudioTrack(int? id) async => _player?.setAudioTrack(id);

  @override
  Future<void> dispose() async {
    // Record where the user actually stopped, not where the last periodic
    // write happened to land.
    final finalState = playback;
    if (finalState.hasMedia) onPositionRecorded(finalState.position);

    await _playbackSubscription?.cancel();
    await _sessionSubscription?.cancel();
    await _session?.dispose();

    // Strictly before the player. The render context holds the engine handle,
    // and freeing them the other way round is a use-after-free that libmpv
    // will only complain about once it is too late.
    await _videoOutput?.dispose();
    await _player?.dispose();
    super.dispose();
  }
}
