import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'combined_chat_demo.dart';
import 'combined_social_feed_demo.dart';
import 'custom_detector_cookbook_demo.dart';
import 'custom_painter_demo.dart';
import 'font_loading_demo.dart';
import 'fps_stress_test_demo.dart';
import 'frame_timing_capture_screen.dart';
import 'gpu_pressure_demo.dart';
import 'heavy_compute_capture_screen.dart';
import 'heavy_compute_demo.dart';
import 'high_level_setstate_demo.dart';
import 'intrinsic_height_demo.dart';
import 'keepalive_demo.dart';
import 'memory_pressure_capture_screen.dart';
import 'memory_pressure_demo.dart';
import 'network_monitor_capture_screen.dart';
import 'network_stress_demo.dart';
import 'non_lazy_list_demo.dart';
import 'platform_channel_capture_screen.dart';
import 'platform_channel_demo.dart';
import 'rebuild_activity_capture_screen.dart';
import 'rebuild_hotspot_demo.dart';
import 'repaint_boundary_demo.dart';
import 'repaint_capture_screen.dart';
import 'repaint_stress_demo.dart';
import 'shader_jank_demo.dart';
import 'shrink_wrapped_sections_demo.dart';
import 'stream_resource_capture_screen.dart';
import 'stream_resource_demo.dart';
import 'tabbed_shell_demo.dart';
import 'tracked_resource_capture_screen.dart';
import 'tracked_resource_demo.dart';
import 'uncached_image_demo.dart';

/// One Sleuth scenario (ported from sleuth 0.37 example).
class SleuthDemoRoute {
  const SleuthDemoRoute({
    required this.id,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.builder,
  });

  /// Stable English slug for `/demo/<id>` reporting.
  final String id;
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final WidgetBuilder builder;

  String get slug => id;
}

class SleuthDemoCategory {
  const SleuthDemoCategory({
    required this.title,
    required this.icon,
    required this.demos,
  });

  final String title;
  final IconData icon;
  final List<SleuthDemoRoute> demos;
}

/// 与 Sleuth 官方 example 目录对齐的中文场景清单。
List<SleuthDemoCategory> sleuthDemoCategories() => [
      SleuthDemoCategory(
        title: '构建 Build',
        icon: Icons.construction,
        demos: [
          SleuthDemoRoute(
            id: 'high_level_setstate',
            icon: Icons.refresh,
            title: '高层 setState',
            subtitle: 'SetStateScope：顶层 setState 重建过大',
            color: Colors.red,
            builder: (_) => const HighLevelSetStateDemo(),
          ),
          SleuthDemoRoute(
            id: 'rebuild_hotspot',
            icon: Icons.insights,
            title: '重建热点（仪表盘）',
            subtitle: 'Rebuild：热点横幅与下钻',
            color: Colors.pink,
            builder: (_) => const RebuildHotspotDemo(),
          ),
          SleuthDemoRoute(
            id: 'non_lazy_list',
            icon: Icons.list,
            title: '非懒加载列表',
            subtitle: 'ListView：一次性构建全部子项',
            color: Colors.orange,
            builder: (_) => const NonLazyListDemo(),
          ),
          SleuthDemoRoute(
            id: 'shrink_wrapped_sections',
            icon: Icons.view_agenda,
            title: 'shrinkWrap 分段列表',
            subtitle: '两段 shrinkWrap 列表的布局成本',
            color: Colors.deepOrange,
            builder: (_) => const ShrinkWrappedSectionsDemo(),
          ),
          SleuthDemoRoute(
            id: 'csv_import',
            icon: Icons.upload_file,
            title: 'CSV 导入（重计算）',
            subtitle: 'HeavyCompute：UI 线程同步解析',
            color: Colors.purple,
            builder: (_) => const HeavyComputeDemo(),
          ),
        ],
      ),
      SleuthDemoCategory(
        title: '绘制 Paint',
        icon: Icons.format_paint,
        demos: [
          SleuthDemoRoute(
            id: 'live_waveform',
            icon: Icons.graphic_eq,
            title: '实时波形（过度重绘）',
            subtitle: 'Repaint：聚合 + 单控件重绘',
            color: Colors.blueGrey,
            builder: (_) => const RepaintStressDemo(),
          ),
          SleuthDemoRoute(
            id: 'always_repaint_painter',
            icon: Icons.brush,
            title: 'Always-Repaint 画笔',
            subtitle: 'CustomPainter：shouldRepaint 恒为 true',
            color: Colors.green,
            builder: (_) => const CustomPainterDemo(),
          ),
          SleuthDemoRoute(
            id: 'missing_repaint_boundary',
            icon: Icons.border_outer,
            title: '缺少 RepaintBoundary',
            subtitle: '结构扫描：重绘边界缺失',
            color: Colors.deepPurple,
            builder: (_) => const RepaintBoundaryDemo(),
          ),
        ],
      ),
      SleuthDemoCategory(
        title: 'GPU 与渲染',
        icon: Icons.layers,
        demos: [
          SleuthDemoRoute(
            id: 'gpu_pressure',
            icon: Icons.memory_outlined,
            title: 'GPU 压力',
            subtitle: 'GpuPressure：混合检测',
            color: Colors.deepOrange,
            builder: (_) => const GpuPressureDemo(),
          ),
          SleuthDemoRoute(
            id: 'shader_jank',
            icon: Icons.blur_on,
            title: 'Shader 卡顿',
            subtitle: '首次编译 pipeline / shader',
            color: Colors.indigo,
            builder: (_) => const ShaderJankDemo(),
          ),
          SleuthDemoRoute(
            id: 'fps_stress',
            icon: Icons.local_fire_department,
            title: 'FPS 压测（~20FPS）',
            subtitle: '每帧重计算 + GPU 模糊',
            color: Colors.red,
            builder: (_) => const FpsStressTestDemo(),
          ),
        ],
      ),
      SleuthDemoCategory(
        title: '布局 Layout',
        icon: Icons.grid_on,
        demos: [
          SleuthDemoRoute(
            id: 'intrinsic_height',
            icon: Icons.height,
            title: '滥用 IntrinsicHeight',
            subtitle: 'LayoutBottleneck：双次布局',
            color: Colors.amber,
            builder: (_) => const IntrinsicHeightDemo(),
          ),
        ],
      ),
      SleuthDemoCategory(
        title: '内存 Memory',
        icon: Icons.memory,
        demos: [
          SleuthDemoRoute(
            id: 'uncached_images',
            icon: Icons.image,
            title: '未缓存图片',
            subtitle: 'ImageMemory：无 cacheWidth/Height',
            color: Colors.teal,
            builder: (_) => const UncachedImageDemo(),
          ),
          SleuthDemoRoute(
            id: 'memory_pressure',
            icon: Icons.data_array,
            title: '内存压力',
            subtitle: 'MemoryPressure：需 VM（profile --no-dds）',
            color: Colors.purple,
            builder: (_) => const MemoryPressureDemo(),
          ),
          SleuthDemoRoute(
            id: 'keepalive',
            icon: Icons.all_inclusive,
            title: 'KeepAlive 过度使用',
            subtitle: 'KeepAlive：存活页过多',
            color: Colors.pink,
            builder: (_) => const KeepAliveDemo(),
          ),
          SleuthDemoRoute(
            id: 'stream_resource',
            icon: Icons.stream,
            title: 'Stream 资源泄漏',
            subtitle: 'StreamResource：Timer / Controller 泄漏',
            color: Colors.deepPurple,
            builder: (_) => const StreamResourceDemo(),
          ),
          SleuthDemoRoute(
            id: 'tracked_resource',
            icon: Icons.bookmark_added,
            title: 'Tracked 资源泄漏',
            subtitle: 'Sleuth.trackResource 保活追踪',
            color: Colors.indigo,
            builder: (_) => const TrackedResourceDemo(),
          ),
        ],
      ),
      SleuthDemoCategory(
        title: '网络与 I/O',
        icon: Icons.cloud,
        demos: [
          SleuthDemoRoute(
            id: 'network_stress',
            icon: Icons.search,
            title: '搜索 + 图库（网络）',
            subtitle: '慢请求 / 过频 / 大响应',
            color: Colors.orange,
            builder: (_) => const NetworkStressDemo(),
          ),
          SleuthDemoRoute(
            id: 'platform_channel',
            icon: Icons.settings_input_hdmi,
            title: 'Platform Channel 过密',
            subtitle: '每秒调用过多（>20）',
            color: Colors.blueGrey,
            builder: (_) => const PlatformChannelDemo(),
          ),
          SleuthDemoRoute(
            id: 'font_loading',
            icon: Icons.font_download,
            title: '字体加载压力',
            subtitle: '自定义字体族过多（>3）',
            color: Colors.deepOrange,
            builder: (_) => const FontLoadingDemo(),
          ),
        ],
      ),
      SleuthDemoCategory(
        title: '导航',
        icon: Icons.tab,
        demos: [
          SleuthDemoRoute(
            id: 'tabbed_shell',
            icon: Icons.view_carousel,
            title: '多 Tab Shell',
            subtitle: 'IndexedStack：每 Tab 一种反模式',
            color: Colors.cyan,
            builder: (_) => const TabbedShellDemo(),
          ),
        ],
      ),
      SleuthDemoCategory(
        title: '自定义 Detector',
        icon: Icons.extension,
        demos: [
          SleuthDemoRoute(
            id: 'custom_detector_cookbook',
            icon: Icons.extension_outlined,
            title: '自定义 Detector 教程',
            subtitle: 'Tooltip · 慢帧 · Raster 热点',
            color: Colors.deepPurple,
            builder: (_) => const CustomDetectorCookbookDemo(),
          ),
        ],
      ),
      SleuthDemoCategory(
        title: '综合场景',
        icon: Icons.dashboard,
        demos: [
          SleuthDemoRoute(
            id: 'combined_social_feed',
            icon: Icons.dynamic_feed,
            title: '综合：社交信息流',
            subtitle: '图片 · 布局 · setState · 关联分析',
            color: Colors.deepPurple,
            builder: (_) => const CombinedSocialFeedDemo(),
          ),
          SleuthDemoRoute(
            id: 'combined_chat',
            icon: Icons.chat,
            title: '综合：聊天页',
            subtitle: 'setState + KeepAlive + Channel',
            color: Colors.blue,
            builder: (_) => const CombinedChatDemo(),
          ),
        ],
      ),
      SleuthDemoCategory(
        title: '采集助手',
        icon: Icons.videocam,
        demos: [
          SleuthDemoRoute(
            id: 'capture_heavy_compute',
            icon: Icons.speed,
            title: 'HeavyCompute 采集',
            subtitle: 'heavy_compute 告警档位标定',
            color: Colors.purple,
            builder: (_) => const HeavyComputeCaptureScreen(),
          ),
          SleuthDemoRoute(
            id: 'capture_rebuild_activity',
            icon: Icons.refresh,
            title: 'RebuildActivity 采集',
            subtitle: 'rebuild_activity 告警档位标定',
            color: Colors.teal,
            builder: (_) => const RebuildActivityCaptureScreen(),
          ),
          SleuthDemoRoute(
            id: 'capture_frame_timing',
            icon: Icons.timeline,
            title: 'FrameTiming 采集',
            subtitle: 'jank_detected 告警档（60Hz）',
            color: Colors.indigo,
            builder: (_) => const FrameTimingCaptureScreen(),
          ),
          SleuthDemoRoute(
            id: 'capture_memory_pressure',
            icon: Icons.data_array,
            title: 'MemoryPressure 采集',
            subtitle: 'heap_growing 告警档位标定',
            color: Colors.purple,
            builder: (_) => const MemoryPressureCaptureScreen(),
          ),
          SleuthDemoRoute(
            id: 'capture_network_monitor',
            icon: Icons.cloud_download,
            title: 'NetworkMonitor 采集',
            subtitle: 'slow_request 告警档位标定',
            color: Colors.orange,
            builder: (_) => const NetworkMonitorCaptureScreen(),
          ),
          SleuthDemoRoute(
            id: 'capture_platform_channel',
            icon: Icons.settings_input_hdmi,
            title: 'PlatformChannel 采集',
            subtitle: 'platform_channel_traffic 告警档',
            color: Colors.blueGrey,
            builder: (_) => const PlatformChannelCaptureScreen(),
          ),
          SleuthDemoRoute(
            id: 'capture_repaint',
            icon: Icons.brush,
            title: 'Repaint 采集',
            subtitle: 'excessive_repaint 告警档位标定',
            color: Colors.pink,
            builder: (_) => const RepaintCaptureScreen(),
          ),
          SleuthDemoRoute(
            id: 'capture_stream_resource',
            icon: Icons.stream,
            title: 'StreamResource 采集',
            subtitle: 'stream_resource_growth 告警档',
            color: Colors.deepPurple,
            builder: (_) => const StreamResourceCaptureScreen(),
          ),
          SleuthDemoRoute(
            id: 'capture_tracked_resource',
            icon: Icons.track_changes,
            title: 'TrackedResource 采集',
            subtitle: 'tracked_resource_concurrent 告警',
            color: Colors.teal,
            builder: (_) => const TrackedResourceCaptureScreen(),
          ),
        ],
      ),
    ];

/// 打开场景页；路由名为 `/demo/<id>`，便于报告归因。
void pushSleuthDemo(BuildContext context, SleuthDemoRoute demo) {
  Get.to(
    () => demo.builder(context),
    routeName: '/demo/${demo.slug}',
    transition: Transition.cupertino,
  );
}
