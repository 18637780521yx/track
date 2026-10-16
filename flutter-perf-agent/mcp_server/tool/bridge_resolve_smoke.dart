import 'package:flutter_perf_agent_mcp/src/bridge_discovery.dart';

Future<void> main() async {
  final url = await BridgeDiscovery.resolve(
    preferredHost: '127.0.0.1',
    preferredPort: 19288,
  );
  print('resolved => $url');
  if (url == null) {
    throw StateError('bridge not found');
  }
}
