/// Playback controls under the video.
library;

import 'package:flutter/material.dart';
import 'package:voracious_core/voracious_core.dart';

String formatDuration(Duration duration) {
  final total = duration.isNegative ? Duration.zero : duration;
  final hours = total.inHours;
  final minutes = total.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = total.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

class TransportBar extends StatefulWidget {
  const TransportBar({
    super.key,
    required this.playback,
    required this.loop,
    required this.onSeek,
    required this.onTogglePause,
    required this.onPreviousCue,
    required this.onNextCue,
    required this.onReplayCue,
    required this.onSetSpeed,
    required this.onClearLoop,
  });

  final PlaybackState playback;
  final AbLoop? loop;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onTogglePause;
  final VoidCallback onPreviousCue;
  final VoidCallback onNextCue;
  final VoidCallback onReplayCue;
  final ValueChanged<double> onSetSpeed;
  final VoidCallback onClearLoop;

  @override
  State<TransportBar> createState() => _TransportBarState();
}

class _TransportBarState extends State<TransportBar> {
  /// While the user is dragging, the slider follows the finger rather than the
  /// engine — otherwise position updates arriving mid-drag fight the drag.
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final playback = widget.playback;
    final duration = playback.duration;
    final position = _dragValue == null
        ? playback.position
        : Duration(milliseconds: _dragValue!.round());

    final maximum = duration.inMilliseconds.toDouble();

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      color: Colors.black,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                formatDuration(position),
                style: const TextStyle(
                  color: Colors.white70,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              Expanded(
                child: Slider(
                  value: maximum <= 0
                      ? 0
                      : position.inMilliseconds.toDouble().clamp(0, maximum),
                  max: maximum <= 0 ? 1 : maximum,
                  onChanged: maximum <= 0
                      ? null
                      : (value) => setState(() => _dragValue = value),
                  onChangeEnd: (value) {
                    setState(() => _dragValue = null);
                    widget.onSeek(Duration(milliseconds: value.round()));
                  },
                ),
              ),
              Text(
                formatDuration(duration),
                style: const TextStyle(
                  color: Colors.white70,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _Button(
                icon: Icons.skip_previous,
                tooltip: 'Previous line (←)',
                onPressed: widget.onPreviousCue,
              ),
              _Button(
                icon: Icons.replay,
                tooltip: 'Replay line (↑)',
                onPressed: widget.onReplayCue,
              ),
              _Button(
                icon: playback.isPlaying ? Icons.pause : Icons.play_arrow,
                tooltip: 'Play/pause (space)',
                size: 34,
                onPressed: widget.onTogglePause,
              ),
              _Button(
                icon: Icons.skip_next,
                tooltip: 'Next line (→)',
                onPressed: widget.onNextCue,
              ),
              const SizedBox(width: 20),
              _SpeedControl(
                speed: playback.speed,
                onChanged: widget.onSetSpeed,
              ),
              if (widget.loop != null) ...[
                const SizedBox(width: 12),
                ActionChip(
                  avatar: const Icon(Icons.loop, size: 16),
                  label: Text(
                    'Loop ${formatDuration(widget.loop!.begin)}'
                    '–${formatDuration(widget.loop!.end)}',
                  ),
                  onPressed: widget.onClearLoop,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 24,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) => IconButton(
        icon: Icon(icon, size: size),
        tooltip: tooltip,
        color: Colors.white,
        onPressed: onPressed,
      );
}

/// Slowing dialogue down is a study aid, so the useful range runs well below
/// 1.0 and barely above it.
class _SpeedControl extends StatelessWidget {
  const _SpeedControl({required this.speed, required this.onChanged});

  final double speed;
  final ValueChanged<double> onChanged;

  static const List<double> _speeds = [0.5, 0.7, 0.85, 1.0, 1.25, 1.5];

  @override
  Widget build(BuildContext context) => PopupMenuButton<double>(
        tooltip: 'Playback speed',
        initialValue: speed,
        onSelected: onChanged,
        itemBuilder: (context) => [
          for (final value in _speeds)
            PopupMenuItem(value: value, child: Text('${value}x')),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            '${speed.toStringAsFixed(2)}x',
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
}
