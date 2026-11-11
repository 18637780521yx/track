import 'package:fast_track_mcp/fast_track_mcp.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_skill/flutter_skill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterExceptionHandler? original;
  final reports = <Map<String, dynamic>>[];
  var originalCalls = 0;

  setUp(() {
    original = FlutterError.onError;
    originalCalls = 0;
    reports.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    FlutterError.onError = (_) => originalCalls++;
    FastTrackMcpCrashHandler.debugOnReport = (name, properties) async {
      reports.add({'name': name, ...properties});
    };
    FastTrackMcpCrashHandler.install();
  });

  tearDown(() async {
    await FastTrackMcpCrashHandler.debugReset();
    FlutterError.onError = original;
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> report() async {
    FlutterError.reportError(FlutterErrorDetails(
      exception: StateError('build failed'),
      stack: StackTrace.current,
      library: 'widgets library',
    ));
    await Future<void>.delayed(Duration.zero);
  }

  test('overwriting integration and FastTracker both receive the error once',
      () async {
    var integrationCalls = 0;
    FastTrackMcpCrashHandler.preserveFlutterErrorHandler(() {
      FlutterError.onError = (_) => integrationCalls++;
    });
    await report();
    expect(integrationCalls, 1);
    expect(originalCalls, 1);
    expect(reports, hasLength(1));
    expect(reports.single['name'], 'app_error');
    expect(reports.single['is_fatal'], false);
    expect(reports.single['stack'], isNotEmpty);
  });

  test(
      'an integration that already forwards cannot duplicate the original handler',
      () async {
    var integrationCalls = 0;
    FastTrackMcpCrashHandler.preserveFlutterErrorHandler(() {
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        integrationCalls++;
        previous?.call(details);
      };
    });
    await report();
    expect(integrationCalls, 1);
    expect(originalCalls, 1);
    expect(reports, hasLength(1));
  });

  test('a failing integration handler cannot block reporting', () async {
    FastTrackMcpCrashHandler.preserveFlutterErrorHandler(() {
      FlutterError.onError = (_) => throw StateError('integration failed');
    });
    await report();
    expect(originalCalls, 1);
    expect(reports, hasLength(1));
  });

  test(
      'partial initialization preserves handlers and propagates the startup error',
      () async {
    var integrationCalls = 0;
    expect(
        () => FastTrackMcpCrashHandler.preserveFlutterErrorHandler(() {
              FlutterError.onError = (_) => integrationCalls++;
              throw StateError('initialization failed');
            }),
        throwsStateError);
    await report();
    expect(integrationCalls, 1);
    expect(originalCalls, 1);
    expect(reports, hasLength(1));
  });

  test('a no-op initializer leaves the handler identity unchanged', () async {
    final before = FlutterError.onError;
    for (var i = 0; i < 3; i++) {
      FastTrackMcpCrashHandler.preserveFlutterErrorHandler(() {});
    }
    expect(FlutterError.onError, same(before));
    await report();
    expect(originalCalls, 1);
    expect(reports, hasLength(1));
  });

  test('actual flutter_skill initialization retains null-assertion reporting',
      () async {
    FastTrackMcpCrashHandler.preserveFlutterErrorHandler(() {
      FlutterSkillBinding.ensureInitialized(autoEnableIndicators: false);
    });
    try {
      final Object? value = null;
      // ignore: unnecessary_non_null_assertion
      value!.toString();
      fail('expected a null assertion error');
    } catch (error, stack) {
      FlutterError.reportError(
          FlutterErrorDetails(exception: error, stack: stack));
    }
    await Future<void>.delayed(Duration.zero);
    expect(originalCalls, 1);
    expect(reports, hasLength(1));
    expect(reports.single['name'], 'app_error');
    expect(reports.single['message'], contains('Null check operator'));
  });
}
