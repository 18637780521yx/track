import Foundation

#if canImport(MetricKit)
import MetricKit
#endif

/// ObjC/Swift uncaught + pending 文件；iOS 14+ 另订 MetricKit 系统 crash/hang 诊断。
/// 未捕获异常的 C 函数指针在 FtmUncaughtException.m，Swift 只传 block。
final class NativeCrashDetector {
  private var running = false
  private let onCrash: ([String: Any]) -> Void
  private var metricKit: AnyObject?
  private var sessionId: String?

  init(onCrash: @escaping ([String: Any]) -> Void) {
    self.onCrash = onCrash
  }

  func start(session: String? = nil) {
    sessionId = session
    if running { flushPending(); return }
    running = true
    flushPending()
    FtmUncaughtExceptionInstall { [weak self] exception in
      self?.handle(exception: exception)
    }
    if #available(iOS 14.0, *) {
      let sub = MetricKitCrashSubscriber { [weak self] payload in
        self?.enqueue(payload) ?? false
      }
      sub.start()
      metricKit = sub
    }
  }

  func stop() {
    guard running else { return }
    running = false
    FtmUncaughtExceptionUninstall()
    if #available(iOS 14.0, *) {
      (metricKit as? MetricKitCrashSubscriber)?.stop()
    }
    metricKit = nil
  }

  private func handle(exception: NSException) {
    let stack = exception.callStackSymbols.joined(separator: "\n")
    let payload: [String: Any] = [
      "crash_id": UUID().uuidString,
      "occurred_at_ms": Int64(Date().timeIntervalSince1970 * 1000),
      "session_id": sessionId ?? "native-recovered",
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
    enqueue(payload)
  }

  private static func recordsURL() -> URL? {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
      .appendingPathComponent("ftm_crash_records", isDirectory: true)
  }

  @discardableResult
  private func enqueue(_ payload: [String: Any]) -> Bool {
    guard let directory = Self.recordsURL() else { return false }
    var record = payload
    let id = record["crash_id"] as? String ?? UUID().uuidString
    record["crash_id"] = id
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent(id + ".json")
      if !FileManager.default.fileExists(atPath: url.path) {
        let data = try JSONSerialization.data(withJSONObject: record)
        try data.write(to: url, options: .atomic)
      }
      DispatchQueue.main.async { [weak self] in self?.onCrash(record) }
      return true
    } catch {
      NSLog("[ftm] crash persistence failed: %@", String(describing: error))
      return false
    }
  }

  func acknowledge(_ id: String) throws {
    guard !id.isEmpty,
      id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
      let directory = Self.recordsURL()
    else { return }
    let url = directory.appendingPathComponent(id + ".json")
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  func replayPending() {
    if running { flushPending() }
  }

  private func flushPending() {
    guard let directory = Self.recordsURL() else { return }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let legacy = directory.deletingLastPathComponent()
        .appendingPathComponent("ftm_pending_native_crash.json")
      if FileManager.default.fileExists(atPath: legacy.path) {
        let data = try Data(contentsOf: legacy)
        if var record = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
          record["crash_id"] = "legacy-native-crash"
          let destination = directory.appendingPathComponent("legacy-native-crash.json")
          let migrated = try JSONSerialization.data(withJSONObject: record)
          try migrated.write(to: destination, options: .atomic)
          try FileManager.default.removeItem(at: legacy)
        }
      }
      for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.pathExtension == "json" {
        do {
          let data = try Data(contentsOf: url)
          if let record = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            DispatchQueue.main.async { [weak self] in self?.onCrash(record) }
          }
        } catch {
          NSLog("[ftm] pending crash read failed: %@", String(describing: error))
        }
      }
    } catch {
      NSLog("[ftm] pending crash replay failed: %@", String(describing: error))
    }
  }
}
