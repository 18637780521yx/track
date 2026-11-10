import Foundation
import MetricKit

/// iOS 14+：系统投递的 crash / hang 诊断（常在下次启动或稍后），作 tombstone 级回捞。
@available(iOS 14.0, *)
final class MetricKitCrashSubscriber: NSObject, MXMetricManagerSubscriber {
  private let onCrash: ([String: Any]) -> Bool
  private var started = false
  private let defaults = UserDefaults.standard
  private let watermarkKey = "ftm_metrickit_diag_watermark"

  init(onCrash: @escaping ([String: Any]) -> Bool) {
    self.onCrash = onCrash
  }

  func start() {
    if started { return }
    started = true
    MXMetricManager.shared.add(self)
  }

  func stop() {
    guard started else { return }
    started = false
    MXMetricManager.shared.remove(self)
  }

  func didReceive(_ payloads: [MXMetricPayload]) {
    // ignore periodic metrics
  }

  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    let watermark = defaults.double(forKey: watermarkKey)
    var maxTs = watermark
    var allPersisted = true

    for payload in payloads {
      let ts = payload.timeStampEnd.timeIntervalSince1970
      if ts <= watermark { continue }
      if ts > maxTs { maxTs = ts }

      if let crashes = payload.crashDiagnostics {
        for (index, diag) in crashes.enumerated() {
          if !emitCrash(diag: diag, timeStamp: ts, index: index) { allPersisted = false }
        }
      }
      if let hangs = payload.hangDiagnostics {
        for (index, diag) in hangs.enumerated() {
          if !emitHang(diag: diag, timeStamp: ts, index: index) { allPersisted = false }
        }
      }
    }

    if allPersisted && maxTs > watermark {
      defaults.set(maxTs, forKey: watermarkKey)
    }
  }

  private func emitCrash(diag: MXCrashDiagnostic, timeStamp: TimeInterval, index: Int) -> Bool {
    let stack = stringifyCallStack(diag.callStackTree)
    let exceptionType =
      diag.exceptionType?.stringValue
      ?? diag.signal?.stringValue
      ?? "MXCrashDiagnostic"
    let message = diag.terminationReason
      ?? diag.exceptionReason
      ?? exceptionType
    var payload: [String: Any] = [
      "crash_id": "metric-crash-\(Int64(timeStamp * 1000))-\(index)",
      "event_type": "native_crash",
      "exception_type": exceptionType,
      "message": message,
      "stack": String(stack.prefix(16_384)),
      "thread": "unknown",
      "is_fatal": true,
      "platform": "ios",
      "crash_source": "metrickit_crash",
      "tombstone": String(stack.prefix(24_576)),
      "tombstone_source": "metrickit_crash",
      "exit_timestamp_ms": Int64(timeStamp * 1000),
    ]
    if let vm = diag.virtualMemoryRegionInfo {
      payload["virtual_memory_region_info"] = vm
    }
    return onCrash(payload)
  }

  private func emitHang(diag: MXHangDiagnostic, timeStamp: TimeInterval, index: Int) -> Bool {
    let stack = stringifyCallStack(diag.callStackTree)
    let hangMs = Int(diag.hangDuration.converted(to: .milliseconds).value)
    let payload: [String: Any] = [
      "crash_id": "metric-hang-\(Int64(timeStamp * 1000))-\(index)",
      "event_type": "native_crash",
      "exception_type": "MXHangDiagnostic",
      "message": "App hang \(hangMs)ms (MetricKit)",
      "stack": String(stack.prefix(16_384)),
      "thread": "main",
      "is_fatal": false,
      "platform": "ios",
      "crash_source": "metrickit_hang",
      "tombstone": String(stack.prefix(24_576)),
      "tombstone_source": "metrickit_hang",
      "blocked_ms": hangMs,
      "exit_timestamp_ms": Int64(timeStamp * 1000),
    ]
    return onCrash(payload)
  }

  private func stringifyCallStack(_ tree: MXCallStackTree) -> String {
    let data = tree.jsonRepresentation()
    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
      return text
    }
    return String(describing: tree)
  }
}
