import 'package:fast_track_mcp_protocol/fast_track_mcp_protocol.dart';

/// Compute a lightweight before/after performance diff on the MCP side.
FastTrackMcpDiffData computeFastTrackMcpDiff({
  required SnapshotPayload before,
  required SnapshotPayload after,
  required int durationMs,
}) {
  return FastTrackMcpDiffData.compute(
    before: before,
    after: after,
    durationMs: durationMs,
  );
}
