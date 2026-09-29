import 'package:flutter/foundation.dart';
import 'package:fast_tools/fast_tools.dart';
import '../tracker_config.dart';

/// SDK 自身版本（与 pubspec.yaml 保持一致）
const String kFastTrackSdkVersion = '0.1.0';

/// 根据 Flutter 编译模式推断环境：debug/profile → sandbox，release → production
TrackEnvironment inferTrackEnvironment() {
  if (kReleaseMode) return TrackEnvironment.production;
  return TrackEnvironment.sandbox;
}

String inferBuildMode() {
  if (kReleaseMode) return 'release';
  if (kProfileMode) return 'profile';
  return 'debug';
}

/// 负责从 fast_tools / 设备环境中读取自动采集属性
class AutoProperties {
  /// 静态属性：设备/应用信息，init 时采集一次即可（不会变化）
  ///
  /// [environment] 可手动指定；为空时按编译模式推断（release→production，其余→sandbox）
  static Map<String, dynamic> staticProperties({
    TrackEnvironment? environment,
  }) {
    final result = <String, dynamic>{};

    // 环境隔离（Adjust 风格）
    final env = environment ?? inferTrackEnvironment();
    result['environment'] = env.wireValue;
    result['build_mode'] = inferBuildMode();
    result['sdk_version'] = kFastTrackSdkVersion;

    // 设备信息
    if (defaultTargetPlatform == TargetPlatform.android) {
      final info = FastAppInfo.androidDeviceInfo;
      result['device_os'] = 'android';
      result['device_os_version'] = info.version.release;
      result['device_model'] = info.model;
      result['device_brand'] = info.brand;
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      final info = FastAppInfo.iosDeviceInfo;
      result['device_os'] = 'ios';
      result['device_os_version'] = info.systemVersion;
      result['device_model'] = info.utsname.machine;
    } else {
      result['device_os'] = defaultTargetPlatform.toString();
      result['device_info'] = FastAppInfo.deviceInfo.data;
    }

    // 应用信息
    final pkg = FastAppInfo.packageInfo;
    result['app_name'] = pkg.appName;
    result['app_version'] = pkg.version;
    result['app_build'] = pkg.buildNumber;
    result['app_package'] = pkg.packageName;
    result['device_udid'] = FastAppInfo.udid;

    // 语言 / 时区（Firebase device 维度常见字段）
    final locale = PlatformDispatcher.instance.locale;
    result['locale'] = locale.toLanguageTag();
    result['language'] = locale.languageCode;
    result['timezone_offset_hours'] = DateTime.now().timeZoneOffset.inHours;

    return result;
  }

  /// 动态属性：每次 track 时实时采集（会随环境变化）
  static Map<String, dynamic> get dynamicProperties {
    return {
      'network_type': FastConnectivity.currentStatus.toString(),
      // 时区夏令时可能变化，每次带上最新值
      'timezone_offset_hours': DateTime.now().timeZoneOffset.inHours,
    };
  }
}
