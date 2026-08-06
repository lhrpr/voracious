/// The widget half of [VideoOutput].
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'video_output.dart';

/// Shows the frames [output] is producing, and keeps it rendering at this
/// widget's size.
///
/// Fills its constraints. There is no [AspectRatio] here on purpose: mpv
/// letterboxes into the surface it is given, so the picture already has the
/// right shape inside the box and the bars are part of the frame. Wrapping
/// this in an [AspectRatio] would add a second set of them.
class VideoSurface extends StatefulWidget {
  const VideoSurface({
    super.key,
    required this.output,
    this.filterQuality = FilterQuality.medium,
  });

  final VideoOutput output;

  /// How Flutter samples the texture. It normally has nothing to do — the
  /// surface is rendered at the widget's exact pixel size — so this only
  /// matters for the frame or two between a resize and mpv catching up.
  final FilterQuality filterQuality;

  @override
  State<VideoSurface> createState() => _VideoSurfaceState();
}

class _VideoSurfaceState extends State<VideoSurface> {
  /// The last size handed to the platform, in physical pixels. Kept so that a
  /// rebuild at an unchanged size costs nothing.
  Size? _reported;

  @override
  void didUpdateWidget(VideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different output has never been told anything about this box.
    if (oldWidget.output.textureId != widget.output.textureId) {
      _reported = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        _report(constraints.biggest * devicePixelRatio);
        return Texture(
          textureId: widget.output.textureId,
          filterQuality: widget.filterQuality,
        );
      },
    );
  }

  void _report(Size pixels) {
    // An unbounded axis means this is being measured rather than laid out;
    // there is no meaningful render size to ask for.
    if (!pixels.isFinite || pixels.isEmpty) return;

    final rounded = Size(
      pixels.width.roundToDouble(),
      pixels.height.roundToDouble(),
    );
    if (rounded == _reported) return;
    _reported = rounded;

    // After the frame, not during it: this runs inside layout, and a channel
    // call from there is a message the platform thread may answer by asking
    // the engine something re-entrantly.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.output.setSurfaceSize(rounded));
    });
  }
}
