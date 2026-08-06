#!/bin/sh
# Builds and runs the headless render probe against a real libmpv.
#
#   tool/render_probe.sh path/to/video.mkv --out /tmp/frame.png
#
# Compiles the plugin's own renderer — the same MpvOpenGLSurface.swift the app
# ships — with no Flutter involved, plays a few seconds, and reports what
# actually landed in the IOSurface. Exits non-zero if no frame arrived or the
# surface came back black.
#
# Needs a libmpv with the OpenGL render API compiled in. That is not the same
# thing as `gpu-api=opengl`, which needs a windowing context an Apple build may
# legitimately lack; see the package README.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
sources="$here/../macos/voracious_video/Sources"
out=${TMPDIR:-/tmp}/voracious_render_probe

swiftc -O \
  -I "$sources/mpv_client_api/include" \
  "$sources/voracious_video/MpvRenderApi.swift" \
  "$sources/voracious_video/MpvOpenGLSurface.swift" \
  "$here/render_probe.swift" \
  -framework OpenGL -framework CoreVideo -framework IOSurface \
  -framework CoreGraphics -framework ImageIO \
  -o "$out"

exec "$out" "$@"
