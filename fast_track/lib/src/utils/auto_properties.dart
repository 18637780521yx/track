import 'package:flutter/foundation.dart';
import 'package:fast_tools/fast_tools.dart';

/// 负责从 fast_tools / 设备环境中读取自动采集属性
class AutoProperties {
  /// 静态属性：设备/应用信息，init 时采集一次即可（不会变化）
  static Map<String, dynamic> get staticProperties {
    final result = <String, dynamic>{};
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
    return result;
  }

  /// 动态属性：每次 track 时实时采集（会随环境变化）
  static Map<String, dynamic> get dynamicProperties {
    return {
      'network_type': FastConnectivity.currentStatus.toString(),
    };
  }
}
