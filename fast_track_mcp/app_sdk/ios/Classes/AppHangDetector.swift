import Foundation
import CoreFoundation
import UIKit

/// Only a busy foreground RunLoop can constitute a hang; sleeping is healthy.
final class AppHangDetector {
  private var observer: CFRunLoopObserver?
  private var timer: DispatchSourceTimer?
  private var notifications: [NSObjectProtocol] = []
  private var busySince: TimeInterval?
  private var foreground = false
  private var timeoutMs = 5000
  private var lastReportAt: TimeInterval = -.infinity
  private var running = false
  private var generation = 0
  private let lock = NSLock()
  private let onHang: ([String: Any]) -> Void

  init(onHang: @escaping ([String: Any]) -> Void) { self.onHang = onHang }

  func start(timeoutMs: Int) {
    lock.lock()
    if running { lock.unlock(); return }
    running = true
    generation += 1
    self.timeoutMs = max(1000, timeoutMs)
    foreground = UIApplication.shared.applicationState == .active
    busySince = nil
    lastReportAt = -.infinity
    lock.unlock()

    let center = NotificationCenter.default
    notifications = [
      center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) {
        [weak self] _ in self?.setForeground(true)
      },
      center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) {
        [weak self] _ in self?.setForeground(false)
      },
    ]
    observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
      CFRunLoopActivity.allActivities.rawValue, true, 0) { [weak self] _, activity in
      self?.activityChanged(activity)
    }
    if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    let period = max(200, self.timeoutMs / 5)
    timer.schedule(deadline: .now() + .milliseconds(period), repeating: .milliseconds(period))
    timer.setEventHandler { [weak self] in self?.check() }
    self.timer = timer
    timer.resume()
  }

  func stop() {
    lock.lock()
    running = false
    generation += 1
    busySince = nil
    lock.unlock()
    timer?.cancel()
    timer = nil
    if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    observer = nil
    notifications.forEach { NotificationCenter.default.removeObserver($0) }
    notifications.removeAll()
  }

  private func setForeground(_ active: Bool) {
    lock.lock()
    foreground = active
    busySince = nil
    generation += 1
    lock.unlock()
  }

  private func activityChanged(_ activity: CFRunLoopActivity) {
    lock.lock()
    defer { lock.unlock() }
    guard running, foreground else { busySince = nil; return }
    if activity == .beforeWaiting || activity == .exit {
      busySince = nil
    } else {
      // Each observer callback proves the main loop has made progress.
      busySince = ProcessInfo.processInfo.systemUptime
    }
  }

  private func check() {
    lock.lock()
    let now = ProcessInfo.processInfo.systemUptime
    guard running, foreground, let since = busySince,
      (now - since) * 1000 >= Double(timeoutMs),
      (now - lastReportAt) * 1000 >= Double(timeoutMs * 3)
    else { lock.unlock(); return }
    lastReportAt = now
    let token = generation
    let blockedMs = Int((now - since) * 1000)
    lock.unlock()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.lock.lock()
      let valid = self.running && self.foreground && self.generation == token
      self.lock.unlock()
      if valid {
        self.onHang(["blocked_ms": blockedMs, "anr_source": "ios_runloop",
          "stack": "", "is_fatal": false, "platform": "ios"])
      }
    }
  }
}
