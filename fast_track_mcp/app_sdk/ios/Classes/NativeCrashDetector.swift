import Foundation

#if canImport(MetricKit)
import MetricKit
#endif

/// ObjC/Swift uncaught + pending 文件；iOS 14+ 另订 MetricKit 系统 crash/hang 诊断。
final class NativeCrashDetector {
  private var previous: NSUncaughtExceptionHandler?
  private var running = false
  private let onCrash: ([String: Any]) -> Void
  private static var shared: NativeCrashDetector?
  private var metricKit: AnyObject?

  init(onCrash: @escaping ([String: Any]) -> Void) {
    self.onCrash = onCrash
  }

  func start() {
    if running { return }
    running = true
    Self.shared = self
    flushPending()
    previous = NSGetUncaughtExceptionHandler()
    NSSetUncaughtExceptionHandler { exception in
      NativeCrashDetector.shared?.handle(exception: exception)
    }
    if #available(iOS 14.0, *) {
      let sub = MetricKitCrashSubscriber { [weak self] payload in
        self?.onCrash(payload)
      }
      sub.start()
      metricKit = sub
    }
  }

  func stop() {
    guard running else { return }
    running = false
    NSSetUncaughtExceptionHandler(previous)
    previous = nil
    if #available(iOS 14.0, *) {
      (metricKit as? MetricKitCrashSubscriber)?.stop()
    }
    metricKit = nil
    if Self.shared === self {
      Self.shared = nil
    }
  }

  private func handle(exception: NSException) {
    let stack = exception.callStackSymbols.joined(separator: "\n")
    let payload: [String: Any] = [
      "event_type": "native_crash",
      "exception_type": exception.name.rawValue,
      "message": exception.reason ?? exception.name.rawValue,
      "stack": String(stack.prefix(16_384)),
      "thread": Thread.current.name ?? "main",
      "is_fatal": true,
      "platform": "ios",
      "crash_source": "uncaught_exception",
      "tombstone": String(stack.prefix(24_576)),
      "tombstone_source": "uncaught_exception",
    ]
    persist(payload)
    DispatchQueue.main.async { [weak self] in
      self?.onCrash(payload)
    }
    previous?(exception)
  }

  private func persist(_ payload: [String: Any]) {
    guard let url = Self.pendingURL() else { return }
    do {
      let data = try JSONSerialization.data(withJSONObject: payload, options: [])
      try data.write(to: url, options: .atomic)
    } catch {
      // ignore
    }
  }

  private func flushPending() {
    guard let url = Self.pendingURL(),
      FileManager.default.fileExists(atPath: url.path)
    else { return }
    do {
      let data = try Data(contentsOf: url)
      try FileManager.default.removeItem(at: url)
      if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
        var map = obj
        map["event_type"] = "native_crash"
        map["crash_source"] = map["crash_source"] ?? "pending_file"
        DispatchQueue.main.async { [weak self] in
          self?.onCrash(map)
        }
      }
    } catch {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private static func pendingURL() -> URL? {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
      .appendingPathComponent("ftm_pending_native_crash.json")
  }
}
