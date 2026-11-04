import Flutter
import UIKit

public class FastTrackMcpPlugin: NSObject, FlutterPlugin {
  private var anrSink: FlutterEventSink?
  private var crashSink: FlutterEventSink?
  private var hangDetector: AppHangDetector?
  private var crashDetector: NativeCrashDetector?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = FastTrackMcpPlugin()

    let method = FlutterMethodChannel(
      name: "fast_track_mcp/anr",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: method)

    let anrEvents = FlutterEventChannel(
      name: "fast_track_mcp/anr_events",
      binaryMessenger: registrar.messenger()
    )
    anrEvents.setStreamHandler(AnrStreamHandler(owner: instance))

    let crashEvents = FlutterEventChannel(
      name: "fast_track_mcp/crash_events",
      binaryMessenger: registrar.messenger()
    )
    crashEvents.setStreamHandler(CrashStreamHandler(owner: instance))

    instance.hangDetector = AppHangDetector { payload in
      var map = payload
      map["event_type"] = "anr"
      instance.anrSink?(map)
    }
    instance.crashDetector = NativeCrashDetector { payload in
      instance.crashSink?(payload)
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      let args = call.arguments as? [String: Any]
      let timeoutMs = (args?["timeoutMs"] as? NSNumber)?.intValue ?? 5000
      hangDetector?.start(timeoutMs: timeoutMs)
      result(["ok": true, "mode": "native"])
    case "stop":
      hangDetector?.stop()
      result(["ok": true])
    case "startCrash":
      crashDetector?.start()
      result(["ok": true, "mode": "native"])
    case "stopCrash":
      crashDetector?.stop()
      result(["ok": true])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  fileprivate func setAnrSink(_ sink: FlutterEventSink?) {
    anrSink = sink
  }

  fileprivate func setCrashSink(_ sink: FlutterEventSink?) {
    crashSink = sink
  }
}

private final class AnrStreamHandler: NSObject, FlutterStreamHandler {
  weak var owner: FastTrackMcpPlugin?

  init(owner: FastTrackMcpPlugin) {
    self.owner = owner
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    owner?.setAnrSink(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    owner?.setAnrSink(nil)
    return nil
  }
}

private final class CrashStreamHandler: NSObject, FlutterStreamHandler {
  weak var owner: FastTrackMcpPlugin?

  init(owner: FastTrackMcpPlugin) {
    self.owner = owner
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    owner?.setCrashSink(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    owner?.setCrashSink(nil)
    return nil
  }
}
