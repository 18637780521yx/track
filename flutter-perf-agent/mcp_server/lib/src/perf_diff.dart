import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';

/// Compute a lightweight before/after performance diff on the MCP side.
PerfDiffData computePerfDiff({
  required SnapshotPayload before,
  required SnapshotPayload after,
  required int durationMs,
}) {
  return PerfDiffData.compute(
    before: before,
    after: after,
    durationMs: durationMs,
  );
}
