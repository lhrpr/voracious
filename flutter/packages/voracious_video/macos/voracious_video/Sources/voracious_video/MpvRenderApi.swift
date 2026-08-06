/// libmpv's render API, resolved at runtime rather than linked.
///
/// Nothing in this package links against libmpv. That is the same arrangement
/// the Dart side uses and for the same reason: an LGPL libmpv used by a
/// proprietary application has to stay replaceable by the user, and a build
/// that linked it would also refuse to launch on a machine without it, in
/// place of the descriptive error `MpvLibrary.open` already produces.
///
/// The path comes across the channel from Dart, which is what makes the two
/// sides agree: `MpvLibrary` records the exact candidate it opened, so
/// `dlopen`ing that path here returns dyld's existing image rather than a
/// second libmpv with its own copy of the engine's globals.
import Foundation
import mpv_client_api

/// Something that went wrong before there was anything to render.
enum MpvRenderError: Error, CustomStringConvertible {
  case libraryUnavailable(path: String, reason: String)
  case symbolMissing(name: String, path: String)
  case invalidHandle
  case contextCreationFailed(code: Int32, message: String)
  case openGLContextFailed(code: Int32)
  case pixelBufferFailed(code: Int32)
  case framebufferIncomplete(status: UInt32)

  var description: String {
    switch self {
    case let .libraryUnavailable(path, reason):
      return "could not open libmpv at \(path): \(reason)"
    case let .symbolMissing(name, path):
      return """
        \(path) does not export \(name). The render API is only present in a \
        libmpv built with OpenGL support; note that this is a separate thing \
        from `gpu-api=opengl`, which needs a windowing context this build may \
        legitimately not have.
        """
    case .invalidHandle:
      return "the mpv handle passed from Dart was null"
    case let .contextCreationFailed(code, message):
      return "mpv_render_context_create failed: \(message) (\(code))"
    case let .openGLContextFailed(code):
      return "could not create an OpenGL context: CGL error \(code)"
    case let .pixelBufferFailed(code):
      return "could not allocate an IOSurface-backed pixel buffer: \(code)"
    case let .framebufferIncomplete(status):
      return "framebuffer incomplete: 0x\(String(status, radix: 16))"
    }
  }
}

/// The subset of libmpv this package calls.
final class MpvRenderApi {
  typealias UpdateCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void

  private typealias ContextCreateFn = @convention(c) (
    UnsafeMutablePointer<OpaquePointer?>?,
    OpaquePointer?,
    UnsafeMutablePointer<mpv_render_param>?
  ) -> Int32
  private typealias ContextFreeFn = @convention(c) (OpaquePointer?) -> Void
  private typealias ContextRenderFn = @convention(c) (
    OpaquePointer?, UnsafeMutablePointer<mpv_render_param>?
  ) -> Int32
  private typealias ContextUpdateFn = @convention(c) (OpaquePointer?) -> UInt64
  private typealias SetUpdateCallbackFn = @convention(c) (
    OpaquePointer?, UpdateCallback?, UnsafeMutableRawPointer?
  ) -> Void
  private typealias ErrorStringFn = @convention(c) (Int32) -> UnsafePointer<CChar>?

  private let contextCreate: ContextCreateFn
  private let contextFree: ContextFreeFn
  private let contextRender: ContextRenderFn
  private let contextUpdate: ContextUpdateFn
  private let setUpdateCallbackFn: SetUpdateCallbackFn
  private let errorString: ErrorStringFn

  /// Marker `MpvLibrary` uses for "already linked into the process", which is
  /// how an embedded framework looks on iOS and tvOS.
  private static let processMarker = "<process>"

  init(libraryPath: String) throws {
    var handle: UnsafeMutableRawPointer?
    if libraryPath == Self.processMarker {
      handle = dlopen(nil, RTLD_NOW)
    } else {
      // RTLD_NOLOAD first, so the common path is provably the image Dart
      // already opened rather than a fresh load that happens to have the same
      // contents. The plain open after it covers a path dyld normalises
      // differently.
      handle = dlopen(libraryPath, RTLD_NOW | RTLD_NOLOAD)
        ?? dlopen(libraryPath, RTLD_NOW)
    }

    // Last resort: the whole process image. A path is only meaningful to the
    // Mach-O image it is resolved against — `@rpath/libmpv.dylib` opens from
    // the Dart VM's image and not from this one, which is a difference no
    // amount of care on the Dart side can fully remove. libmpv is loaded by
    // the time anything here runs, so asking the global scope for its symbols
    // finds the same library the handle came from.
    let resolvedByGlobalScope = handle == nil
    if handle == nil { handle = dlopen(nil, RTLD_NOW) }

    guard let handle else {
      let reason = String(cString: dlerror() ?? strdup("unknown error"))
      throw MpvRenderError.libraryUnavailable(path: libraryPath, reason: reason)
    }
    if resolvedByGlobalScope,
      dlsym(handle, "mpv_render_context_create") == nil
    {
      throw MpvRenderError.libraryUnavailable(
        path: libraryPath,
        reason: "not loadable from this image, and no libmpv is loaded in the "
          + "process")
    }

    func symbol<T>(_ name: String, as type: T.Type) throws -> T {
      guard let pointer = dlsym(handle, name) else {
        throw MpvRenderError.symbolMissing(name: name, path: libraryPath)
      }
      return unsafeBitCast(pointer, to: type)
    }

    contextCreate = try symbol("mpv_render_context_create", as: ContextCreateFn.self)
    contextFree = try symbol("mpv_render_context_free", as: ContextFreeFn.self)
    contextRender = try symbol("mpv_render_context_render", as: ContextRenderFn.self)
    contextUpdate = try symbol("mpv_render_context_update", as: ContextUpdateFn.self)
    setUpdateCallbackFn = try symbol(
      "mpv_render_context_set_update_callback", as: SetUpdateCallbackFn.self)
    errorString = try symbol("mpv_error_string", as: ErrorStringFn.self)
  }

  func describe(_ code: Int32) -> String {
    guard let text = errorString(code) else { return "error \(code)" }
    return String(cString: text)
  }

  /// Creates a render context on [handle] drawing through OpenGL.
  ///
  /// The caller's GL context must be current on the calling thread: mpv
  /// resolves its entry points and allocates GL objects during this call.
  func createContext(
    mpvHandle: OpaquePointer,
    getProcAddress: @escaping @convention(c) (
      UnsafeMutableRawPointer?, UnsafePointer<CChar>?
    ) -> UnsafeMutableRawPointer?,
    getProcAddressContext: UnsafeMutableRawPointer?
  ) throws -> OpaquePointer {
    var initParams = mpv_opengl_init_params(
      get_proc_address: getProcAddress,
      get_proc_address_ctx: getProcAddressContext
    )
    let apiType = strdup(MPV_RENDER_API_TYPE_OPENGL)
    defer { free(apiType) }

    var context: OpaquePointer?
    let code = withUnsafeMutablePointer(to: &initParams) { initPointer -> Int32 in
      var params = [
        mpv_render_param(
          type: MPV_RENDER_PARAM_API_TYPE,
          data: UnsafeMutableRawPointer(apiType)),
        mpv_render_param(
          type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
          data: UnsafeMutableRawPointer(initPointer)),
        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
      ]
      return contextCreate(&context, mpvHandle, &params)
    }

    guard code >= 0, let context else {
      throw MpvRenderError.contextCreationFailed(code: code, message: describe(code))
    }
    return context
  }

  /// Draws the current frame into [fbo], which must be complete and bound to a
  /// texture of the same size.
  ///
  /// Note what is *not* here: `MPV_RENDER_PARAM_FLIP_Y`. The reflex is to set
  /// it — OpenGL's framebuffer origin is bottom-left, every Apple surface is
  /// top-down, so a flip looks obviously required. It is not, because the
  /// binding in between already accounts for it: `CGLTexImageIOSurface2D` maps
  /// GL's row 0 to the *last* row of the IOSurface, so mpv drawing the top of
  /// the picture at GL's top puts it at the surface's first row, which is
  /// where CoreVideo expects it. Asking for a flip as well inverts a correct
  /// image.
  ///
  /// This is exactly the kind of claim that should not rest on reasoning:
  /// `tool/render_probe.sh` renders a frame and writes it out, and the two
  /// possibilities are told apart at a glance.
  @discardableResult
  func render(
    context: OpaquePointer, fbo: UInt32, width: Int, height: Int,
    internalFormat: Int32
  ) -> Int32 {
    var target = mpv_opengl_fbo(
      fbo: Int32(fbo),
      w: Int32(width),
      h: Int32(height),
      internal_format: internalFormat
    )

    return withUnsafeMutablePointer(to: &target) { targetPointer in
      var params = [
        mpv_render_param(
          type: MPV_RENDER_PARAM_OPENGL_FBO,
          data: UnsafeMutableRawPointer(targetPointer)),
        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
      ]
      return contextRender(context, &params)
    }
  }

  /// True when mpv has a new frame waiting.
  func hasNewFrame(context: OpaquePointer) -> Bool {
    contextUpdate(context) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0
  }

  func setUpdateCallback(
    context: OpaquePointer, callback: UpdateCallback?, userData: UnsafeMutableRawPointer?
  ) {
    setUpdateCallbackFn(context, callback, userData)
  }

  /// Frees the context. The GL context must be current: mpv deletes the
  /// objects it allocated during creation.
  func freeContext(_ context: OpaquePointer) {
    contextFree(context)
  }
}
