/// Presents an [MpvOpenGLSurface] to Flutter as a texture.
///
/// Everything hard is next door in `MpvOpenGLSurface`, which knows nothing
/// about Flutter so that it can be run headlessly. What is left here is the
/// adapter: a texture id, a `copyPixelBuffer` that hands over the frame the
/// surface finished last, and the notification that says a new one exists.
import CoreVideo
import FlutterMacOS
import Foundation

@available(macOS, deprecated: 10.14, message: "mpv's render API has no Metal backend")
final class MpvVideoRenderer: NSObject, FlutterTexture {
  private let registry: FlutterTextureRegistry
  private var surface: MpvOpenGLSurface!
  private var textureId: Int64 = 0

  init(
    api: MpvRenderApi,
    mpvHandle: OpaquePointer,
    registry: FlutterTextureRegistry,
    width: Int,
    height: Int
  ) throws {
    self.registry = registry
    super.init()

    surface = try MpvOpenGLSurface(
      api: api,
      mpvHandle: mpvHandle,
      width: width,
      height: height,
      onFrame: { [weak self] in
        guard let self, self.textureId != 0 else { return }
        self.registry.textureFrameAvailable(self.textureId)
      }
    )
  }

  /// Registers with Flutter and starts rendering.
  ///
  /// The texture id has to exist before the first frame can be announced,
  /// which is why the surface is not started in `init`.
  func start() -> Int64 {
    textureId = registry.register(self)
    surface.start()
    return textureId
  }

  func setSurfaceSize(width: Int, height: Int) {
    surface.setSurfaceSize(width: width, height: height)
  }

  // MARK: - FlutterTexture

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    guard let buffer = surface.currentPixelBuffer() else { return nil }
    return Unmanaged.passRetained(buffer)
  }

  // MARK: - Teardown

  /// Releases the render context, then calls [completion] on the main thread.
  ///
  /// The caller must not destroy the mpv handle until [completion] has run.
  /// Asynchronous rather than blocking so that the platform thread stays free
  /// while the render queue finishes — see `MpvOpenGLSurface.dispose`.
  func dispose(completion: @escaping () -> Void) {
    let id = textureId
    textureId = 0
    surface.dispose {
      DispatchQueue.main.async {
        if id != 0 { self.registry.unregisterTexture(id) }
        completion()
      }
    }
  }
}
