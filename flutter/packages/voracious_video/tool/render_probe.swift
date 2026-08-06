/// Drives the real render path against a real libmpv, with no Flutter and no
/// display, and writes out what landed in the surface.
///
/// This exists because "is there a picture" is otherwise unanswerable without
/// a running app, a window, and a human looking at it. `MpvOpenGLSurface` is
/// deliberately free of Flutter for exactly this reason: the probe compiles
/// the same file the plugin ships and reports what mpv actually drew.
///
/// It also catches the failure this path is most likely to have and least
/// likely to notice — a channel swap. `CGLTexImageIOSurface2D` is handed a
/// swizzle triple, and getting it wrong produces a picture that is perfectly
/// sharp, correctly timed, and has red and blue exchanged. The summary prints
/// per-channel means, and against a colour-bar clip a swap is unmistakable.
///
/// Build and run it with `tool/render_probe.sh`.
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

// MARK: - Just enough of the libmpv client API to get a file playing.

private typealias CreateFn = @convention(c) () -> OpaquePointer?
private typealias InitializeFn = @convention(c) (OpaquePointer?) -> Int32
private typealias TerminateFn = @convention(c) (OpaquePointer?) -> Void
private typealias SetOptionFn = @convention(c) (
  OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
) -> Int32
private typealias CommandFn = @convention(c) (
  OpaquePointer?, UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> Int32
private typealias GetPropertyStringFn = @convention(c) (
  OpaquePointer?, UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?
/// mpv allocates through talloc, so what `mpv_get_property_string` hands back
/// is not a malloc block — it points into the middle of one. Releasing it with
/// `free` corrupts the heap, and the abort surfaces later on some unrelated
/// thread, which is a miserable thing to debug. `mpv_free` is not a courtesy.
private typealias FreeFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

private struct Mpv {
  let handle: OpaquePointer
  let libraryPath: String
  private let library: UnsafeMutableRawPointer
  private let setOptionFn: SetOptionFn
  private let commandFn: CommandFn
  private let terminateFn: TerminateFn
  private let getPropertyStringFn: GetPropertyStringFn
  private let freeFn: FreeFn

  init(libraryPath: String) throws {
    guard let library = dlopen(libraryPath, RTLD_NOW) else {
      throw ProbeError("could not open \(libraryPath)")
    }
    self.library = library
    self.libraryPath = libraryPath

    func symbol<T>(_ name: String, as type: T.Type) throws -> T {
      guard let pointer = dlsym(library, name) else {
        throw ProbeError("\(libraryPath) does not export \(name)")
      }
      return unsafeBitCast(pointer, to: type)
    }

    let create = try symbol("mpv_create", as: CreateFn.self)
    let initialize = try symbol("mpv_initialize", as: InitializeFn.self)
    setOptionFn = try symbol("mpv_set_option_string", as: SetOptionFn.self)
    commandFn = try symbol("mpv_command", as: CommandFn.self)
    terminateFn = try symbol("mpv_terminate_destroy", as: TerminateFn.self)
    getPropertyStringFn = try symbol(
      "mpv_get_property_string", as: GetPropertyStringFn.self)
    freeFn = try symbol("mpv_free", as: FreeFn.self)

    guard let handle = create() else { throw ProbeError("mpv_create returned null") }
    self.handle = handle

    // The same shape MpvConfiguration produces, trimmed to what a probe needs.
    for (name, value) in [
      ("vo", "libmpv"), ("ao", "null"), ("terminal", "no"), ("config", "no"),
      ("osc", "no"), ("osd-level", "0"), ("input-default-bindings", "no"),
      ("hwdec", "videotoolbox"), ("keep-open", "yes"), ("idle", "yes"),
    ] {
      if setOptionFn(handle, name, value) < 0 {
        FileHandle.standardError.write(
          Data("warning: mpv rejected \(name)=\(value)\n".utf8))
      }
    }

    if initialize(handle) < 0 { throw ProbeError("mpv_initialize failed") }
  }

  func command(_ arguments: [String]) throws {
    var pointers: [UnsafePointer<CChar>?] = arguments.map { UnsafePointer(strdup($0)) }
    pointers.append(nil)
    defer { for pointer in pointers where pointer != nil { free(UnsafeMutableRawPointer(mutating: pointer!)) } }
    if commandFn(handle, &pointers) < 0 {
      throw ProbeError("mpv command failed: \(arguments.joined(separator: " "))")
    }
  }

  func property(_ name: String) -> String? {
    guard let raw = getPropertyStringFn(handle, name) else { return nil }
    defer { freeFn(UnsafeMutableRawPointer(raw)) }
    return String(cString: raw)
  }

  func terminate() {
    terminateFn(handle)
    dlclose(library)
  }
}

private struct ProbeError: Error, CustomStringConvertible {
  init(_ description: String) { self.description = description }
  let description: String
}

// MARK: - Reading the surface back

/// Per-channel means over the frame, plus how much of it is not black.
private struct FrameSummary {
  let width: Int
  let height: Int
  let red: Double
  let green: Double
  let blue: Double
  let litFraction: Double

  var description: String {
    String(
      format: "%dx%d  mean R=%.1f G=%.1f B=%.1f  non-black %.1f%%",
      width, height, red, green, blue, litFraction * 100)
  }
}

private func summarise(_ buffer: CVPixelBuffer, writingTo path: String?) throws
  -> FrameSummary
{
  CVPixelBufferLockBaseAddress(buffer, .readOnly)
  defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

  let width = CVPixelBufferGetWidth(buffer)
  let height = CVPixelBufferGetHeight(buffer)
  let stride = CVPixelBufferGetBytesPerRow(buffer)
  guard let base = CVPixelBufferGetBaseAddress(buffer) else {
    throw ProbeError("pixel buffer has no base address")
  }
  let bytes = base.assumingMemoryBound(to: UInt8.self)

  var totals = (r: 0.0, g: 0.0, b: 0.0)
  var lit = 0
  for y in 0..<height {
    let row = bytes + y * stride
    for x in 0..<width {
      // 32BGRA: blue, green, red, alpha.
      let blue = Double(row[x * 4 + 0])
      let green = Double(row[x * 4 + 1])
      let red = Double(row[x * 4 + 2])
      totals.b += blue
      totals.g += green
      totals.r += red
      if blue + green + red > 24 { lit += 1 }
    }
  }

  let count = Double(width * height)
  let summary = FrameSummary(
    width: width, height: height,
    red: totals.r / count, green: totals.g / count, blue: totals.b / count,
    litFraction: Double(lit) / count)

  if let path {
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
      .union(.byteOrder32Little)
    guard
      let context = CGContext(
        data: base, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: info.rawValue),
      let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else {
      throw ProbeError("could not encode \(path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw ProbeError("could not write \(path)")
    }
  }

  return summary
}

// MARK: - Main

@available(macOS, deprecated: 10.14)
private func run() throws {
  var arguments = Array(CommandLine.arguments.dropFirst())
  guard !arguments.isEmpty else {
    throw ProbeError(
      "usage: render_probe <video> [--out frame.png] [--seconds 3] "
        + "[--size 1280x720] [--library /path/to/libmpv.dylib]")
  }

  let videoPath = arguments.removeFirst()
  var outputPath: String?
  var seconds = 3.0
  var width = 1280
  var height = 720
  var libraryPath = "/usr/local/lib/libmpv.dylib"

  while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    guard !arguments.isEmpty else { throw ProbeError("\(flag) needs a value") }
    let value = arguments.removeFirst()
    switch flag {
    case "--out": outputPath = value
    case "--seconds": seconds = Double(value) ?? seconds
    case "--library": libraryPath = value
    case "--size":
      let parts = value.split(separator: "x")
      guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else {
        throw ProbeError("--size wants WIDTHxHEIGHT")
      }
      (width, height) = (w, h)
    default: throw ProbeError("unknown flag \(flag)")
    }
  }

  let mpv = try Mpv(libraryPath: libraryPath)
  let api = try MpvRenderApi(libraryPath: libraryPath)

  let frames = Counter()
  let surface = try MpvOpenGLSurface(
    api: api, mpvHandle: mpv.handle, width: width, height: height,
    onFrame: { frames.increment() })
  surface.start()

  try mpv.command(["loadfile", videoPath])
  Thread.sleep(forTimeInterval: seconds)

  let rendered = frames.value
  print("frames rendered: \(rendered) in \(seconds)s")
  print("video size: \(mpv.property("width") ?? "?")x\(mpv.property("height") ?? "?")")
  print("hwdec in use: \(mpv.property("hwdec-current") ?? "?")")

  guard let buffer = surface.currentPixelBuffer() else {
    throw ProbeError("no frame was ever produced")
  }
  let summary = try summarise(buffer, writingTo: outputPath)
  print("surface: \(summary.description)")
  if let outputPath { print("wrote \(outputPath)") }

  // The teardown order the plugin has to honour: render context first, engine
  // second. Doing it here means the probe would catch getting it wrong.
  let done = DispatchSemaphore(value: 0)
  surface.dispose { done.signal() }
  done.wait()
  mpv.terminate()

  guard rendered > 0 else { throw ProbeError("mpv never called back with a frame") }
  guard summary.litFraction > 0.01 else {
    throw ProbeError("the surface is black; mpv rendered nothing into it")
  }
}

/// Frames arrive on mpv's render queue and are counted from the main thread.
private final class Counter {
  private let lock = NSLock()
  private var count = 0
  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

/// Marked in step with `MpvOpenGLSurface`, which is deprecated in step with
/// the OpenGL it is built on.
@available(macOS, deprecated: 10.14)
@main
struct RenderProbe {
  static func main() {
    do {
      try run()
    } catch {
      FileHandle.standardError.write(Data("render_probe: \(error)\n".utf8))
      exit(1)
    }
  }
}
