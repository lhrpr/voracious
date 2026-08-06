/// The player screen.
///
/// The keyboard layout is the one the Electron app taught its users, and it is
/// deliberate that the down arrow is the single "continue" key: in every mode
/// it means "I am done with this line", and the mode decides whether that
/// reveals another track or resumes playback. The user learns one key, not
/// four behaviours.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voracious_core/voracious_core.dart';
import 'package:voracious_video/voracious_video.dart';

import '../state/library_controller.dart';
import '../state/player_controller.dart';
import '../widgets/subtitle_stack.dart';
import '../widgets/transport_bar.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.video,
    required this.library,
  });

  final VideoEntry video;
  final LibraryController library;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  PlayerController? _controller;
  final FocusNode _focusNode = FocusNode();
  bool _showHelp = false;

  @override
  void initState() {
    super.initState();
    _showHelp = widget.library.preferences.showHelp;
    unawaited(_start());
  }

  Future<void> _start() async {
    final resumeFrom = await widget.library.resumePositionFor(widget.video.id);

    final controller = PlayerController(
      video: widget.video,
      preferences: widget.library.preferences,
      resumeFrom: resumeFrom,
      onPositionRecorded: (position) =>
          widget.library.recordPosition(widget.video.id, position),
    );

    controller.addListener(_onChanged);
    setState(() => _controller = controller);
    await controller.start();
    if (mounted) _focusNode.requestFocus();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_onChanged);
    unawaited(_controller?.dispose());
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final controller = _controller;
    if (controller == null || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        unawaited(controller.togglePause());
      case LogicalKeyboardKey.arrowDown:
        unawaited(controller.continueStudy());
      case LogicalKeyboardKey.arrowUp:
        unawaited(controller.replayCurrentCue());
      case LogicalKeyboardKey.arrowLeft:
        unawaited(controller.previousCue());
      case LogicalKeyboardKey.arrowRight:
        unawaited(controller.nextCue());
      case LogicalKeyboardKey.keyR:
        controller.revealAll();
      case LogicalKeyboardKey.keyL:
        controller.loop == null
            ? controller.loopCurrentCue()
            : controller.clearLoop();
      case LogicalKeyboardKey.keyH:
        setState(() => _showHelp = !_showHelp);
      case LogicalKeyboardKey.escape:
        Navigator.of(context).maybePop();
      default:
        // Number keys toggle individual tracks in manual mode.
        final label = event.logicalKey.keyLabel;
        final digit = int.tryParse(label);
        if (digit != null && digit >= 1 && digit <= 9) {
          controller.toggleTrackHidden(digit - 1);
        } else {
          return KeyEventResult.ignored;
        }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.video.name),
        actions: [
          if (controller != null)
            _ModeSelector(
              mode: controller.mode,
              onChanged: controller.setMode,
            ),
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'Keyboard help (H)',
            onPressed: () => setState(() => _showHelp = !_showHelp),
          ),
        ],
      ),
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKey,
        child: controller == null
            ? const Center(child: CircularProgressIndicator())
            : _PlayerBody(controller: controller, showHelp: _showHelp),
      ),
    );
  }
}

class _PlayerBody extends StatelessWidget {
  const _PlayerBody({required this.controller, required this.showHelp});

  final PlayerController controller;
  final bool showHelp;

  @override
  Widget build(BuildContext context) {
    if (controller.stage == PlayerLoadStage.failed) {
      return _LoadFailure(message: controller.error ?? 'unknown error');
    }

    final snapshot = controller.snapshot;
    final output = controller.videoOutput;

    // A file with no video track still renders — as black — so the notice is
    // decided by the engine's report rather than by whether a surface exists.
    final hasPicture = controller.playback.videoWidth != null;

    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              const Positioned.fill(child: ColoredBox(color: Colors.black)),
              if (output != null)
                Positioned.fill(child: VideoSurface(output: output)),
              if (output == null || !hasPicture)
                Positioned.fill(
                  child: _NoPictureNotice(
                    reason: controller.videoOutputError,
                    stage: controller.stage,
                  ),
                ),
              if (snapshot != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 26,
                  child: SubtitleStack(
                    snapshot: snapshot,
                    showRuby: controller.preferences.showRuby,
                    fontScale: controller.preferences.subtitleFontScale,
                    onRevealTrack: controller.revealAll,
                  ),
                ),
              if (controller.stage != PlayerLoadStage.ready)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 16,
                  child: Center(
                    child: _StageBadge(stage: controller.stage),
                  ),
                ),
              if (showHelp)
                const Positioned(top: 16, right: 16, child: _HelpOverlay()),
            ],
          ),
        ),
        TransportBar(
          playback: controller.playback,
          loop: controller.loop,
          onSeek: controller.seek,
          onTogglePause: controller.togglePause,
          onPreviousCue: controller.previousCue,
          onNextCue: controller.nextCue,
          onReplayCue: controller.replayCurrentCue,
          onSetSpeed: controller.setSpeed,
          onClearLoop: controller.clearLoop,
        ),
      ],
    );
  }
}

/// Shown over the surface when there is nothing on it.
///
/// Two different situations, and telling them apart is the point. A file with
/// no video track is normal and needs no explanation beyond the icon. Video
/// output that failed to start is not, and the reason has to be readable —
/// it is usually a libmpv without the render API compiled in, which nothing
/// else on screen would hint at.
class _NoPictureNotice extends StatelessWidget {
  const _NoPictureNotice({required this.reason, required this.stage});

  final String? reason;
  final PlayerLoadStage stage;

  @override
  Widget build(BuildContext context) {
    // Before the engine reports a track list there is nothing to say yet, and
    // a notice that appears for half a second on every video is worse than no
    // notice at all.
    if (reason == null && stage != PlayerLoadStage.ready) {
      return const SizedBox.shrink();
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              reason == null ? Icons.music_note : Icons.videocam_off_outlined,
              size: 40,
              color: Colors.white24,
            ),
            const SizedBox(height: 8),
            Text(
              reason == null ? 'Audio only' : 'No video output',
              style: const TextStyle(color: Colors.white24, fontSize: 13),
            ),
            if (reason != null) ...[
              const SizedBox(height: 6),
              SelectableText(
                reason!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white24, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StageBadge extends StatelessWidget {
  const _StageBadge({required this.stage});

  final PlayerLoadStage stage;

  @override
  Widget build(BuildContext context) {
    final label = switch (stage) {
      PlayerLoadStage.idle => 'Waiting',
      PlayerLoadStage.startingEngine => 'Starting mpv',
      PlayerLoadStage.openingFile => 'Opening file',
      PlayerLoadStage.loadingSubtitles => 'Loading subtitles',
      PlayerLoadStage.ready => 'Ready',
      PlayerLoadStage.failed => 'Failed',
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white54, size: 40),
              const SizedBox(height: 12),
              const Text(
                'Could not start playback',
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
              const SizedBox(height: 8),
              SelectableText(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      );
}

class _ModeSelector extends StatelessWidget {
  const _ModeSelector({required this.mode, required this.onChanged});

  final SubtitleMode mode;
  final ValueChanged<SubtitleMode> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<SubtitleMode>(
        tooltip: 'Study mode',
        initialValue: mode,
        onSelected: onChanged,
        itemBuilder: (context) => [
          for (final value in SubtitleMode.values)
            PopupMenuItem(
              value: value,
              child: ListTile(
                dense: true,
                title: Text(value.displayName),
                subtitle: SizedBox(
                  width: 320,
                  child: Text(
                    value.description,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Text(
                mode.displayName,
                style: const TextStyle(color: Colors.white),
              ),
              const Icon(Icons.arrow_drop_down, color: Colors.white),
            ],
          ),
        ),
      );
}

class _HelpOverlay extends StatelessWidget {
  const _HelpOverlay();

  static const List<(String, String)> _bindings = [
    ('Space', 'Play / pause'),
    ('↓', 'Continue — reveal the next track, or resume'),
    ('↑', 'Replay the current line'),
    ('← / →', 'Previous / next line'),
    ('1…9', 'Toggle one track (manual mode)'),
    ('R', 'Reveal everything'),
    ('L', 'Loop the current line / clear the loop'),
    ('H', 'Show or hide this help'),
    ('Esc', 'Back to the library'),
  ];

  @override
  Widget build(BuildContext context) => Container(
        width: 330,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (key, description) in _bindings)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 62,
                      child: Text(
                        key,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        description,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
}
