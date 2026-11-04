import 'package:flutter_perf_agent_mcp/src/flutter_skill_vm_client.dart';
import 'package:test/test.dart';

void main() {
  test('normalizeWsUri keeps token and adds /ws', () {
    final ws = FlutterSkillVmClient.normalizeWsUri(
      'http://127.0.0.1:55647/tdwdJNSOJO4=/',
    );
    expect(ws, 'ws://127.0.0.1:55647/tdwdJNSOJO4=/ws');
  });
}
