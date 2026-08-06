/// The subtitle area of the player.
///
/// Renders exactly what [StudySessionSnapshot] says and nothing more. A hidden
/// track still occupies its space: if revealing a line made the others jump,
/// the reveal would be a visual event rather than a reading one, and in
/// listening practice the user is looking right at it.
library;

import 'package:flutter/material.dart';
import 'package:voracious_core/voracious_core.dart';

import 'annotated_text_view.dart';

class SubtitleStack extends StatelessWidget {
  const SubtitleStack({
    super.key,
    required this.snapshot,
    required this.showRuby,
    required this.fontScale,
    this.onRevealTrack,
  });

  final StudySessionSnapshot snapshot;
  final bool showRuby;
  final double fontScale;

  /// Clicking a hidden track reveals everything, which is the mouse equivalent
  /// of the reveal-all key.
  final VoidCallback? onRevealTrack;

  @override
  Widget build(BuildContext context) {
    if (snapshot.tracks.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < snapshot.tracks.length; index++)
          _TrackLine(
            displayed: snapshot.tracks[index],
            // The first track is the one the study modes take their timing
            // from, so it is the one drawn largest.
            isPrimary: index == 0,
            showRuby: showRuby,
            fontScale: fontScale,
            onReveal: onRevealTrack,
          ),
      ],
    );
  }
}

class _TrackLine extends StatelessWidget {
  const _TrackLine({
    required this.displayed,
    required this.isPrimary,
    required this.showRuby,
    required this.fontScale,
    this.onReveal,
  });

  final DisplayedTrack displayed;
  final bool isPrimary;
  final bool showRuby;
  final double fontScale;
  final VoidCallback? onReveal;

  @override
  Widget build(BuildContext context) {
    final cue = displayed.cue;
    final size = (isPrimary ? 30.0 : 22.0) * fontScale;

    final style = TextStyle(
      fontSize: size,
      height: 1.35,
      color: Colors.white,
      fontWeight: isPrimary ? FontWeight.w500 : FontWeight.w400,
      shadows: const [
        // A drop shadow rather than a background box: subtitles have to stay
        // readable over both a white sky and a night scene, and a box over
        // every line covers more of the picture than it needs to.
        Shadow(blurRadius: 5, color: Colors.black87),
        Shadow(blurRadius: 14, color: Colors.black54),
      ],
    );

    if (cue == null) {
      // Reserve the line's height so the stack does not shift between lines.
      return SizedBox(height: size * 1.6);
    }

    if (displayed.isHidden) {
      return _HiddenLine(height: size * 1.6, onReveal: onReveal);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: AnnotatedTextView(
        text: cue.text,
        style: style,
        showRuby: showRuby,
      ),
    );
  }
}

/// A track the mode is withholding: present, obviously concealing something,
/// and one click from being revealed.
class _HiddenLine extends StatelessWidget {
  const _HiddenLine({required this.height, this.onReveal});

  final double height;
  final VoidCallback? onReveal;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: Center(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onReveal,
              child: Container(
                width: 190,
                height: 7,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
        ),
      );
}
