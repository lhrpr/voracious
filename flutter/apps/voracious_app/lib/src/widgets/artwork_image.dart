/// A poster or still from the artwork cache, with a placeholder while it loads
/// or when there is none.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:voracious_core/voracious_core_io.dart';

class ArtworkImage extends StatefulWidget {
  const ArtworkImage({
    super.key,
    required this.url,
    required this.cache,
    required this.width,
    required this.height,
    this.placeholderIcon = Icons.image_outlined,
    this.borderRadius = 4,
  });

  final String? url;

  /// Null shows the placeholder only (tests, metadata switched off).
  final IoArtworkCache? cache;
  final double width;
  final double height;
  final IconData placeholderIcon;
  final double borderRadius;

  @override
  State<ArtworkImage> createState() => _ArtworkImageState();
}

class _ArtworkImageState extends State<ArtworkImage> {
  File? _file;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ArtworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _load();
  }

  void _load() {
    final url = widget.url;
    final cache = widget.cache;
    if (url == null || cache == null) {
      _file = null;
      return;
    }
    // Already on disk: show it in this frame, without a flash of placeholder.
    _file = cache.peek(url);
    if (_file != null) return;
    cache.fetch(url).then((file) {
      if (mounted && widget.url == url) setState(() => _file = file);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final file = _file;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: file == null
            ? ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: Icon(
                  widget.placeholderIcon,
                  size: widget.height.clamp(12, 28).toDouble(),
                  color: scheme.onSurfaceVariant,
                ),
              )
            : Image.file(
                file,
                fit: BoxFit.cover,
                // Decode at display size; a 342px poster shown at 46px should
                // not hold the full bitmap in memory for every row.
                cacheWidth: (widget.width * pixelRatio).round(),
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => ColoredBox(
                  color: scheme.surfaceContainerHighest,
                ),
              ),
      ),
    );
  }
}
