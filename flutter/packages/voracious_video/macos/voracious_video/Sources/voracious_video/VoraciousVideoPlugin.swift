/// The channel between Dart and the renderer.
///
/// Deliberately thin. Dart owns the engine's lifetime and knows when a file is
/// about to be opened; this side owns a GL context and a texture and knows
/// nothing about playback. The only state it keeps is which renderer belongs
/// to which texture id.
import FlutterMacOS
import Foundation

public class VoraciousVideoPlugin: NSObject, FlutterPlugin {
  private let registrar: FlutterPluginRegistrar

  /// Live renderers by texture id. Only ever touched from the platform thread,
  /// which is where method channel calls are delivered.
  ///
  /// Typed as `NSObject` so that naming the renderer — deprecated along with
  /// the OpenGL it is built on — stays inside the methods annotated for it.
  private var renderers: [Int64: NSObject] = [:]

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "voracious_video", binaryMessenger: registrar.messenger)
    let instance = VoraciousVideoPlugin(registrar: registrar)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  /// Deprecated in step with `MpvVideoRenderer`, which is deprecated in step
  /// with OpenGL. Flutter dispatches here through the Objective-C runtime, so
  /// there is no Swift call site to inherit the warning.
  @available(macOS, deprecated: 10.14)
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "create":
      create(call.arguments, result: result)
    case "setSurfaceSize":
      setSurfaceSize(call.arguments, result: result)
    case "dispose":
      dispose(call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  @available(macOS, deprecated: 10.14)
  private func create(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let arguments = arguments as? [String: Any],
      let handleAddress = (arguments["handle"] as? NSNumber)?.int64Value,
      let libraryPath = arguments["libraryPath"] as? String
    else {
      result(
        FlutterError(
          code: "bad-arguments",
          message: "create needs handle, libraryPath, width and height",
          details: nil))
      return
    }

    let width = (arguments["width"] as? NSNumber)?.intValue ?? 1
    let height = (arguments["height"] as? NSNumber)?.intValue ?? 1

    guard let mpvHandle = OpaquePointer(bitPattern: Int(handleAddress)) else {
      result(
        FlutterError(
          code: "no-engine",
          message: MpvRenderError.invalidHandle.description,
          details: nil))
      return
    }

    do {
      let api = try MpvRenderApi(libraryPath: libraryPath)
      let renderer = try MpvVideoRenderer(
        api: api,
        mpvHandle: mpvHandle,
        registry: registrar.textures,
        width: width,
        height: height
      )
      let textureId = renderer.start()
      renderers[textureId] = renderer
      result(NSNumber(value: textureId))
    } catch let error as MpvRenderError {
      result(FlutterError(code: "render-init", message: error.description, details: nil))
    } catch {
      result(
        FlutterError(
          code: "render-init", message: "\(error)", details: nil))
    }
  }

  @available(macOS, deprecated: 10.14)
  private func setSurfaceSize(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let arguments = arguments as? [String: Any],
      let textureId = (arguments["textureId"] as? NSNumber)?.int64Value,
      let width = (arguments["width"] as? NSNumber)?.intValue,
      let height = (arguments["height"] as? NSNumber)?.intValue
    else {
      result(
        FlutterError(
          code: "bad-arguments",
          message: "setSurfaceSize needs textureId, width and height",
          details: nil))
      return
    }

    // A size for a texture that has already gone is not an error: the widget
    // can be laid out one more time after the controller disposed the output.
    (renderers[textureId] as? MpvVideoRenderer)?
      .setSurfaceSize(width: width, height: height)
    result(nil)
  }

  @available(macOS, deprecated: 10.14)
  private func dispose(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let arguments = arguments as? [String: Any],
      let textureId = (arguments["textureId"] as? NSNumber)?.int64Value
    else {
      result(
        FlutterError(
          code: "bad-arguments", message: "dispose needs textureId", details: nil))
      return
    }

    // Removed first, so a second dispose — which Dart's own teardown makes
    // easy to arrange — finds nothing rather than freeing twice.
    guard let renderer = renderers.removeValue(forKey: textureId)
      as? MpvVideoRenderer
    else {
      result(nil)
      return
    }

    // The reply is what tells Dart it is safe to destroy the engine handle the
    // render context was holding, so it waits for the teardown rather than
    // acknowledging the request.
    renderer.dispose { result(nil) }
  }
}
