// 本地埋点接收服务：接收 POST 请求并打印 body，返回 200
// 运行：dart run tool/serve_track.dart [端口]
// 默认：http://127.0.0.1:8080

import 'dart:convert';
import 'dart:io';

const _defaultPort = 8080;

void main(List<String> args) async {
  var port = int.tryParse(args.isNotEmpty ? args[0] : '') ?? _defaultPort;
  HttpServer? server;
  // 0.0.0.0 允许模拟器/真机通过本机 IP（如 192.168.x.x）连接
  final host = InternetAddress.anyIPv4;
  for (var i = 0; i < 20; i++) {
    try {
      server = await HttpServer.bind(host, port);
      break;
    } on SocketException catch (_) {
      if (i < 19) {
        port++;
        continue;
      }
      print('Port $port in use. Try: dart run tool/serve_track.dart ${port + 1}');
      exit(1);
    }
  }
  if (server == null) exit(1);
  print('Track server listening on http://0.0.0.0:$port');
  print('Example: 本机 http://127.0.0.1:$port/track  模拟器/真机 http://<本机IP>:$port/track');
  print('Ctrl+C to stop.\n');

  await for (final request in server) {
    if (request.method == 'POST') {
      try {
        final parts = await request.toList();
        final body = parts.expand((x) => x).toList();
        var raw = utf8.decode(body);
        final encoding = request.headers.value('content-encoding');
        if (encoding?.toLowerCase() == 'gzip') {
          try {
            raw = utf8.decode(_gzipDecode(body));
          } catch (_) {
            print('[warn] gzip decode failed, print raw length: ${body.length}');
          }
        }
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded.containsKey('events')) {
          final events = decoded['events'] as List? ?? [];
          print('[$_now] received ${events.length} event(s):');
          for (var i = 0; i < events.length; i++) {
            final e = events[i] is Map ? events[i] as Map : {};
            print('  ${i + 1}. ${e['name']} ${e['timestamp']} event_id=${e['event_id']}');
          }
        } else {
          print('[$_now] body: $decoded');
        }
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'ok': true}))
          ..close();
      } catch (e) {
        print('[$_now] error: $e');
        request.response.statusCode = 500;
        request.response.close();
      }
    } else {
      request.response.statusCode = 405;
      request.response.close();
    }
  }
}

String get _now =>
    DateTime.now().toIso8601String().replaceFirst('T', ' ').substring(0, 19);

List<int> _gzipDecode(List<int> data) {
  return GZipCodec().decode(data);
}
