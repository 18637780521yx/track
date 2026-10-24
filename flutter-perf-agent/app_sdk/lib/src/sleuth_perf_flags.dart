/// Process-wide gate for Sleuth-backed perf capture → journal.
///
/// Covers [FrameJankLatch], [SleuthIssueLatch], and transition sleuth bind.
/// Crash / network / WeakRef leak are independent. Default **off**.
class SleuthPerfFlags {
  SleuthPerfFlags._();

  static bool enabled = false;
}
