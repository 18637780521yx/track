import Foundation
import CoreFoundation

/// Main RunLoop stall detector (iOS App Hang analogue).
/// CFRunLoopObserver stamps last activity; a background timer fires when idle too long.
final class AppHangDetector {
  private var observer: CFRunLoopObserver?
  private var timer: DispatchSourceTimer?
  private var lastActivity = Date()
  private var timeoutMs: Int = 5000
  private var lastReportAt: Date = .distantPast
  private var running = false
  private let lock = NSLock()
  private let onHang: ([String: Any]) -> Void

  init(onHang: @escaping ([String: Any]) -> Void) {
    self.onHang = onHang
  }

  func start(timeoutMs: Int) {
    lock.lock()
    defer { lock.unlock() }
    if running { return }
    running = true
    self.timeoutMs = max(1000, timeoutMs)
    lastActivity = Date()

    let activities: CFRunLoopActivity = [
      .entry, .beforeTimers, .beforeSources, .beforeWaiting, .afterWaiting, .exit,
    ]
    observer = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault,
      activities.rawValue,
      true,
      0
    ) { [weak self] _, _ in
      self?.stamp()
    }
    if let observer {
      CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    // Poll at ~1/5 of timeout so we notice stalls promptly without busy looping.
    let period = max(200, self.timeoutMs / 5)
    timer.schedule(deadline: .now() + .milliseconds(period), repeating: .milliseconds(period))
    timer.setEventHandler { [weak self] in
      self?.check()
    }
    self.timer = timer
    timer.resume()
  }

  func stop() {
    lock.lock()
    defer { lock.unlock() }
    running = false
    timer?.cancel()
    timer = nil
    if let observer {
      CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
    observer = nil
  }

  private func stamp() {
    lock.lock()
    lastActivity = Date()
    lock.unlock()
  }

  private func check() {
    lock.lock()
    guard running else {
      lock.unlock()
      return
    }
    let idleMs = Date().timeIntervalSince(lastActivity) * 1000.0
    let timeout = Double(timeoutMs)
    let sinceReport = Date().timeIntervalSince(lastReportAt) * 1000.0
    let cooldown = timeout * 3
    if idleMs < timeout || sinceReport < cooldown {
      lock.unlock()
      return
    }
    lastReportAt = Date()
    lock.unlock()

    // Main-thread symbols aren't freely available without mach APIs; leave stack empty.
    let payload: [String: Any] = [
      "blocked_ms": Int(idleMs),
      "anr_source": "ios_runloop",
      "stack": "",
      "is_fatal": false,
      "platform": "ios",
    ]
    DispatchQueue.main.async { [weak self] in
      self?.onHang(payload)
    }
  }
}
