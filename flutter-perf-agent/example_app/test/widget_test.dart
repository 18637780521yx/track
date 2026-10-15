import 'package:flutter_test/flutter_test.dart';

import 'package:example_app/main.dart';

void main() {
  testWidgets('login page shows brand and login button', (tester) async {
    await tester.pumpWidget(const PerfDemoApp());
    expect(find.text('Perf Agent Demo'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
  });
}
