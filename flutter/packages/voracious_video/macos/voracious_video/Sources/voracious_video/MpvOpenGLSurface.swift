/// Draws an mpv render context into IOSurface-backed pixel buffers.
///
/// The shape of this is dictated by what the two ends can accept. Flutter's
/// macOS embedder takes video frames as `CVPixelBuffer`s and turns them into
/// Metal textures; mpv's render API draws into an OpenGL framebuffer object.
/// An `IOSurface` is what bridges them: a pixel buffer backed by one can be
/// bound as a GL texture with `CGLTexImageIOSurface2D` and read by Metal
/// without the frame ever leaving the GPU. The alternative — mpv's software
/// render API into a malloc'd buffer — would pull every frame back across the
/// bus, and at 1080p60 that is about 500 MB/s of pure waste.
///
/// Nothing here knows about Flutter. That is deliberate: it is what lets the
/// whole render path be exercised headlessly by `tool/render_probe.swift`,
/// which is the only way to answer "is there actually a correct picture in
/// that surface" without a display, a running app, and a screenshot.
///
/// Everything touching GL happens on one serial queue, because a CGL context
/// is not thread-safe and mpv's render calls implicitly use whichever context
/// is current on the calling thread. The one exception is
/// [currentPixelBuffer], which the consumer calls from its own thread and
/// which only takes a reference.
import CoreVideo
import Foundation
import IOSurface
import OpenGL
import OpenGL.GL3
import OpenGL.IOSurface
import mpv_client_api

/// OpenGL is deprecated on macOS and there is no replacement mpv's render API
/// can target: it offers an OpenGL backend and a software one, and nothing in
/// between. Marking the whole class deprecated is what stops every GL call
/// inside it from raising a warning of its own.
@available(macOS, deprecated: 10.14, message: "mpv's render API has no Metal backend")
final class MpvOpenGLSurface {
  /// One frame's worth of GPU objects: an IOSurface-backed pixel buffer, the
  /// rectangle texture that aliases it, and the framebuffer mpv draws into.
  private struct RenderTarget {
    let pixelBuffer: CVPixelBuffer
    let texture: GLuint
    let framebuffer: GLuint
    let width: Int
    let height: Int
  }

  private let api: MpvRenderApi
  private let glContext: CGLContextObj
  private let openGLFramework: UnsafeMutableRawPointer
  private var renderContext: OpaquePointer?

  /// Called after each frame lands, on the render queue. Whatever is showing
  /// the surface uses this to ask for [currentPixelBuffer].
  private let onFrame: () -> Void

  /// Everything GL happens here, in order.
  private let queue = DispatchQueue(
    label: "com.voracious.video.render", qos: .userInteractive)

  /// Guards [targets] and [frontIndex], which the consumer's thread reads.
  private let bufferLock = NSLock()
  private var targets: [RenderTarget] = []

  /// Index of the finished frame, or -1 before the first one. [onFrame] fires
  /// only after this is set, so it is never read early.
  private var frontIndex = -1
  private var backIndex = 0

  /// Guards the scheduling flags, which mpv's thread and the caller's thread
  /// both touch.
  private let scheduleLock = NSLock()
  private var renderScheduled = false
  private var forceNextRender = false
  private var requestedWidth: Int
  private var requestedHeight: Int

  private var disposed = false

  /// Two buffers, so mpv is not drawing into the surface being read.
  ///
  /// Not a complete guarantee — the consumer holds the buffer it was handed
  /// until it has copied from it, and nothing here waits for that — but with
  /// two in rotation the surface being drawn into is the one released a frame
  /// ago, and video frame rates are below display refresh in every case that
  /// matters. A third would close the remaining window at the cost of another
  /// full-resolution surface.
  private static let bufferCount = 2

  init(
    api: MpvRenderApi,
    mpvHandle: OpaquePointer,
    width: Int,
    height: Int,
    onFrame: @escaping () -> Void
  ) throws {
    self.api = api
    self.onFrame = onFrame
    self.requestedWidth = max(1, width)
    self.requestedHeight = max(1, height)

    guard
      let framework = dlopen(
        "/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_NOW | RTLD_LOCAL)
    else {
      throw MpvRenderError.libraryUnavailable(
        path: "OpenGL.framework",
        reason: String(cString: dlerror() ?? strdup("unknown error")))
    }
    openGLFramework = framework
    glContext = try Self.makeGLContext()

    // mpv resolves its GL entry points and allocates objects during creation,
    // so the context has to be current on this thread — and it has to be this
    // thread, the one every later render call will run on.
    var creationError: Error?
    queue.sync {
      CGLSetCurrentContext(glContext)
      do {
        renderContext = try api.createContext(
          mpvHandle: mpvHandle,
          getProcAddress: { context, name in
            guard let context, let name else { return nil }
            return dlsym(context, name)
          },
          getProcAddressContext: framework
        )
      } catch {
        creationError = error
      }
      CGLSetCurrentContext(nil)
    }

    if let creationError {
      CGLDestroyContext(glContext)
      dlclose(framework)
      throw creationError
    }
  }

  /// Starts accepting frames from mpv.
  ///
  /// Separate from `init` because the update callback must not fire before the
  /// consumer is ready to be told about a frame.
  func start() {
    guard let renderContext else { return }
    api.setUpdateCallback(
      context: renderContext,
      callback: { context in
        guard let context else { return }
        Unmanaged<MpvOpenGLSurface>.fromOpaque(context)
          .takeUnretainedValue()
          .requestRender(force: false)
      },
      userData: Unmanaged.passUnretained(self).toOpaque()
    )
    // Draw once immediately: with nothing loaded this is a black frame, which
    // beats the undefined contents of a surface that has never been written.
    requestRender(force: true)
  }

  /// Sets the size mpv renders at, in physical pixels.
  ///
  /// This is the size of the box the video is shown in, not the size of the
  /// video. mpv scales and letterboxes into whatever framebuffer it is given
  /// and applies the display aspect ratio while doing it, so sizing to the box
  /// keeps anamorphic video correct without the caller knowing anything about
  /// pixel aspect, and scales a 4K file once rather than twice.
  func setSurfaceSize(width: Int, height: Int) {
    scheduleLock.lock()
    let changed = requestedWidth != max(1, width) || requestedHeight != max(1, height)
    requestedWidth = max(1, width)
    requestedHeight = max(1, height)
    scheduleLock.unlock()

    // Forced, because a resize while paused produces no new frame and would
    // otherwise leave the old surface stretched across the new bounds.
    if changed { requestRender(force: true) }
  }

  /// The most recently completed frame, or nil before the first one.
  func currentPixelBuffer() -> CVPixelBuffer? {
    bufferLock.lock()
    defer { bufferLock.unlock() }
    guard frontIndex >= 0, frontIndex < targets.count else { return nil }
    return targets[frontIndex].pixelBuffer
  }

  // MARK: - Rendering

  /// Asks for a frame. Safe to call from any thread, including mpv's.
  private func requestRender(force: Bool) {
    scheduleLock.lock()
    if force { forceNextRender = true }
    let alreadyScheduled = renderScheduled
    renderScheduled = true
    scheduleLock.unlock()

    // One pass in flight at a time. mpv's render call blocks until the frame's
    // display time, so queueing a block per callback would build a backlog of
    // waits rather than drawing sooner.
    guard !alreadyScheduled else { return }
    queue.async { [weak self] in self?.renderPass() }
  }

  private func renderPass() {
    scheduleLock.lock()
    renderScheduled = false
    let force = forceNextRender
    forceNextRender = false
    let width = requestedWidth
    let height = requestedHeight
    scheduleLock.unlock()

    guard !disposed, let renderContext else { return }

    CGLSetCurrentContext(glContext)
    CGLLockContext(glContext)
    var published = false
    defer {
      CGLUnlockContext(glContext)
      CGLSetCurrentContext(nil)
      if published { onFrame() }
    }

    var mustDraw = force
    // Only this queue writes `targets`, so reading it here needs no lock; the
    // lock is for the consumer's thread in `currentPixelBuffer`.
    if targets.isEmpty || targets[0].width != width || targets[0].height != height {
      do {
        try rebuildTargets(width: width, height: height)
      } catch {
        NSLog("voracious_video: could not size the render surface: \(error)")
        return
      }
      mustDraw = true
    }

    guard mustDraw || api.hasNewFrame(context: renderContext) else { return }

    let target = targets[backIndex]
    let code = api.render(
      context: renderContext,
      fbo: target.framebuffer,
      width: target.width,
      height: target.height,
      internalFormat: GL_RGBA8
    )
    guard code >= 0 else {
      NSLog("voracious_video: mpv_render_context_render failed: \(api.describe(code))")
      return
    }

    // The IOSurface is read outside this GL context entirely — by Metal, in
    // the Flutter case. Without a flush the reader may see a half-drawn frame.
    glFlush()

    bufferLock.lock()
    frontIndex = backIndex
    backIndex = (backIndex + 1) % targets.count
    bufferLock.unlock()
    published = true
  }

  /// Allocates a fresh set of surfaces at [width] x [height].
  ///
  /// Called on the render queue with the GL context current and locked.
  private func rebuildTargets(width: Int, height: Int) throws {
    var replacements: [RenderTarget] = []
    replacements.reserveCapacity(Self.bufferCount)
    for _ in 0..<Self.bufferCount {
      replacements.append(try makeTarget(width: width, height: height))
    }

    bufferLock.lock()
    let previous = targets
    targets = replacements
    // Nothing in the new surfaces has been drawn yet, so there is no front
    // buffer until this pass finishes.
    frontIndex = -1
    backIndex = 0
    bufferLock.unlock()

    // Safe even if the consumer still holds one of these pixel buffers: it
    // retains the buffer, which owns the IOSurface. Only this side's aliases
    // go away.
    releaseTargets(previous)
  }

  private func makeTarget(width: Int, height: Int) throws -> RenderTarget {
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferWidthKey: width,
      kCVPixelBufferHeightKey: height,
      // An empty dictionary still means "back this with an IOSurface", which
      // is the whole point: without one there is nothing GL and Metal can
      // share.
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
      kCVPixelBufferMetalCompatibilityKey: true,
      kCVPixelBufferOpenGLCompatibilityKey: true,
    ]

    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      attributes as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let buffer,
      let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
    else {
      throw MpvRenderError.pixelBufferFailed(code: status)
    }

    var texture: GLuint = 0
    glGenTextures(1, &texture)
    glBindTexture(GLenum(GL_TEXTURE_RECTANGLE), texture)
    // Rectangle textures, not GL_TEXTURE_2D: IOSurface interop supports only
    // the rectangle target. BGRA with the reversed packing is the swizzle that
    // makes GL's RGBA writes land in the byte order CoreVideo promised its
    // reader.
    let bound = CGLTexImageIOSurface2D(
      glContext,
      GLenum(GL_TEXTURE_RECTANGLE),
      GLenum(GL_RGBA),
      GLsizei(width),
      GLsizei(height),
      GLenum(GL_BGRA),
      GLenum(GL_UNSIGNED_INT_8_8_8_8_REV),
      surface,
      0
    )
    guard bound == kCGLNoError else {
      glDeleteTextures(1, &texture)
      throw MpvRenderError.openGLContextFailed(code: Int32(bound.rawValue))
    }
    glTexParameteri(
      GLenum(GL_TEXTURE_RECTANGLE), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
    glTexParameteri(
      GLenum(GL_TEXTURE_RECTANGLE), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
    glBindTexture(GLenum(GL_TEXTURE_RECTANGLE), 0)

    var framebuffer: GLuint = 0
    glGenFramebuffers(1, &framebuffer)
    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
    glFramebufferTexture2D(
      GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
      GLenum(GL_TEXTURE_RECTANGLE), texture, 0)
    let completeness = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
    guard completeness == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
      glDeleteFramebuffers(1, &framebuffer)
      glDeleteTextures(1, &texture)
      throw MpvRenderError.framebufferIncomplete(status: completeness)
    }

    return RenderTarget(
      pixelBuffer: buffer, texture: texture, framebuffer: framebuffer,
      width: width, height: height)
  }

  // MARK: - Teardown

  /// Releases everything, then calls [completion] on the render queue.
  ///
  /// Asynchronous on purpose. Tearing down means waiting for whatever render
  /// pass is in flight, and that pass ends by calling [onFrame] — which, for
  /// the Flutter consumer, hands work to the platform thread. Blocking the
  /// platform thread to wait for a queue that is trying to talk to it is how
  /// that deadlocks.
  ///
  /// Must complete before the mpv handle is destroyed: the render context
  /// holds it, and libmpv says so out loud — "Broken API use:
  /// mpv_render_context_free() not called" — once it is too late to matter.
  func dispose(completion: @escaping () -> Void) {
    queue.async { [self] in
      defer { completion() }
      guard !disposed else { return }
      disposed = true

      if let renderContext {
        // Stop new work arriving before anything is freed. mpv guarantees the
        // callback is not running once free() returns; clearing it first means
        // the queue is not still being fed while that happens.
        api.setUpdateCallback(context: renderContext, callback: nil, userData: nil)

        CGLSetCurrentContext(glContext)
        CGLLockContext(glContext)
        // Deletes the GL objects mpv allocated, so the context must be current.
        api.freeContext(renderContext)

        bufferLock.lock()
        let previous = targets
        targets = []
        frontIndex = -1
        backIndex = 0
        bufferLock.unlock()
        releaseTargets(previous)

        CGLUnlockContext(glContext)
        CGLSetCurrentContext(nil)
        self.renderContext = nil
      }

      CGLDestroyContext(glContext)
      dlclose(openGLFramework)
    }
  }

  /// Deletes this side's aliases of [targets]. GL context must be current.
  private func releaseTargets(_ targets: [RenderTarget]) {
    for target in targets {
      var texture = target.texture
      var framebuffer = target.framebuffer
      glDeleteFramebuffers(1, &framebuffer)
      glDeleteTextures(1, &texture)
    }
  }

  // MARK: - OpenGL context

  private static func makeGLContext() throws -> CGLContextObj {
    var attributes: [CGLPixelFormatAttribute] = [
      kCGLPFAOpenGLProfile,
      CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
      kCGLPFAAccelerated,
      // Lets CGL pick a renderer on the GPU actually driving the display,
      // which keeps the IOSurface handoff on one device on machines with more
      // than one.
      kCGLPFAAllowOfflineRenderers,
      kCGLPFAColorSize, CGLPixelFormatAttribute(24),
      kCGLPFAAlphaSize, CGLPixelFormatAttribute(8),
      CGLPixelFormatAttribute(0),
    ]

    var pixelFormat: CGLPixelFormatObj?
    var formatCount: GLint = 0
    var code = CGLChoosePixelFormat(&attributes, &pixelFormat, &formatCount)
    guard code == kCGLNoError, let pixelFormat else {
      throw MpvRenderError.openGLContextFailed(code: Int32(code.rawValue))
    }
    defer { CGLDestroyPixelFormat(pixelFormat) }

    var context: CGLContextObj?
    code = CGLCreateContext(pixelFormat, nil, &context)
    guard code == kCGLNoError, let context else {
      throw MpvRenderError.openGLContextFailed(code: Int32(code.rawValue))
    }
    return context
  }
}
