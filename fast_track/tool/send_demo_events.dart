import 'dart:io';

import 'package:fast_track/fast_track.dart';
import 'package:fast_tools/fast_tools.dart';
import 'package:flutter/widgets.dart';

/// 向 track-server 上报一批演示数据，然后退出。
/// 运行：cd fast_track && flutter run -t tool/send_demo_events.dart -d macos
const _trackUrl = 'http://127.0.0.1:8080/track';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FastTools.init();

  await FastTracker.init(
    url: _trackUrl,
    config: const TrackerConfig(
      enableDebugLog: true,
      flushInterval: const Duration(hours: 1),
      maxBatchSize: 20,
      checkNetworkBeforeFlush: false,
    ),
    initialCommonProperties: {'source': 'send_demo_events'},
  );

  // 用户 Alice：完整转化路径
  FastTracker.tracker.identify('demo_alice');
  await FastTracker.track('app_first_open', properties: {'channel': 'app_store'});
  await FastTracker.track('app_daily_active');
  await FastTracker.track('page_view', properties: {'page_name': 'home', 'from_page': ''});
  await FastTracker.track('page_view', properties: {'page_name': 'detail', 'from_page': 'home'});
  await FastTracker.track('btn_click', properties: {'btn': 'subscribe', 'page_name': 'detail'});
  await FastTracker.track('payment_success',
      properties: {'amount': 29.9, 'currency': 'CNY', 'plan': 'monthly'});
  await FastTracker.track('subscription_start', properties: {
    'plan': 'monthly',
    'amount': 29.9,
    'currency': 'CNY',
    'expires_at': DateTime.now().add(const Duration(days: 30)).toUtc().toIso8601String(),
  });

  // 用户 Bob：浏览但未付费
  FastTracker.tracker.resetIdentity();
  FastTracker.tracker.identify('demo_bob');
  await FastTracker.track('app_first_open', properties: {'channel': 'google_play'});
  await FastTracker.track('page_view', properties: {'page_name': 'home'});
  await FastTracker.track('page_view', properties: {'page_name': 'pricing'});
  await FastTracker.track('btn_click', properties: {'btn': 'trial', 'page_name': 'pricing'});

  // 用户 Carol：匿名用户，仅首开
  FastTracker.tracker.resetIdentity();
  await FastTracker.track('app_first_open', properties: {'channel': 'organic'});
  await FastTracker.track('page_view', properties: {'page_name': 'onboarding'});

  await FastTracker.tracker.flush();

  stdout.writeln('fast_track demo events sent to $_trackUrl');
  exit(0);
}
