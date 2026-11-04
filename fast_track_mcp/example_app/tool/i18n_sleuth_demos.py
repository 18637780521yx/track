#!/usr/bin/env python3
"""Translate Sleuth demo catalog + DemoScaffold title/description to 中文."""

from __future__ import annotations

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1] / "lib" / "sleuth_demos"

# file -> (zh_title, zh_description)  — description uses Dart adjacent strings
DEMOS: dict[str, tuple[str, str]] = {
    "high_level_setstate_demo.dart": (
        "高层 setState",
        """\
          '问题：顶层 setState 会在每次点击时重建全部 $_itemCount 个格子，'
          '即使只有一个数字变了。\\n'
          '修复：把可变状态放进 ValueNotifier，只用 ValueListenableBuilder '
          '包住真正展示的控件；网格本身保持不变、不再重建。\\n\\n'
          '点右下角 +，观察「重建次数」。错误写法每次按都会重建 $_itemCount '
          '个格子；正确写法只有计数芯片会重建。'""",
    ),
    "rebuild_hotspot_demo.dart": (
        "重建热点（仪表盘）",
        """\
          '问题：ValueListenableBuilder 包住了整个假仪表盘，任一数值变化'
          '都会重建整棵大子树。\\n'
          '修复：把监听范围收窄到真正依赖该数值的叶子控件。\\n\\n'
          '打开 Sleuth 浮层，对比错误/正确模式下的 rebuild 热点。'""",
    ),
    "non_lazy_list_demo.dart": (
        "非懒加载列表",
        """\
          '问题：SingleChildScrollView + Column 一次性构建 $_itemCount 个子项。\\n'
          '修复：改用 ListView.builder（可加 itemExtent），只构建可见项。\\n\\n'
          '滚动列表并看「已构建」计数：错误路径立刻构建全部；正确路径通常只构建十几项。'""",
    ),
    "shrink_wrapped_sections_demo.dart": (
        "shrinkWrap 分段列表",
        """\
          '问题：两个 ListView(shrinkWrap: true) 嵌在外层滚动里，会先量完全部子项。\\n'
          '修复：用 CustomScrollView + SliverList，交给同一套懒加载滚动。\\n\\n'
          '对比两种写法的构建开销与卡顿。'""",
    ),
    "heavy_compute_demo.dart": (
        "CSV 导入（重计算）",
        """\
          '问题：在 UI 线程同步解析超大 CSV，阻塞帧渲染。\\n'
          '修复：用 Isolate.run / compute 把解析挪出 UI 线程。\\n\\n'
          '点导入，观察 FPS / HeavyCompute issue；正确模式应明显更顺。'""",
    ),
    "repaint_stress_demo.dart": (
        "实时波形（过度重绘）",
        """\
          '问题：60Hz CustomPaint 波形与周围静态 UI 画在同一层，整屏跟着重绘。\\n'
          '修复：给动画区域加 RepaintBoundary，隔离重绘范围。\\n\\n'
          '切换错误/正确模式，看 Repaint 相关 issue。'""",
    ),
    "custom_painter_demo.dart": (
        "Always-Repaint 画笔",
        """\
          '问题：shouldRepaint 永远返回 true，Flutter 无法跳过绘制。\\n'
          '修复：仅在数据真正变化时返回 true。\\n\\n'
          '切换模式后观察 CustomPainter 相关检测。'""",
    ),
    "repaint_boundary_demo.dart": (
        "缺少 RepaintBoundary",
        """\
          '问题：Opacity / CustomPaint 没有 RepaintBoundary，父级重绘牵连整片。\\n'
          '修复：给高频重绘子树包上 RepaintBoundary。\\n\\n'
          '对比结构扫描给出的 missing_repaint_boundary。'""",
    ),
    "gpu_pressure_demo.dart": (
        "GPU 压力",
        """\
          '问题：叠加昂贵 GPU 操作（模糊、裁剪、滤色等）导致 raster 占主导。\\n'
          '修复：减少层数/特效，缓存静态图层，避免每帧全屏模糊。\\n\\n'
          '打开动画后看 GPU Pressure / raster_dominance。'""",
    ),
    "shader_jank_demo.dart": (
        "Shader 卡顿",
        """\
          '问题：首次编译 pipeline/shader 会造成掉帧。\\n'
          '修复：使用 Impeller，或在启动后做暖机帧预编译。\\n\\n'
          '进入「着色器重屏」，观察 shader_compilation issue。'""",
    ),
    "fps_stress_test_demo.dart": (
        "FPS 压测（~20FPS）",
        """\
          '问题：每帧排序 5 万项并做多重 GPU 模糊，故意把帧率压到约 20。\\n'
          '用途：验证 FPS / jank 指标与报告是否灵敏。\\n\\n'
          '进入页面后观察 FPS 与卡顿告警。'""",
    ),
    "intrinsic_height_demo.dart": (
        "滥用 IntrinsicHeight",
        """\
          '问题：用 IntrinsicHeight 包 Row 会强制两次布局，列表越大越慢。\\n'
          '修复：改用固定高度、Align、或自定义布局避免 intrinsic 测量。\\n\\n'
          '滚动并观察 LayoutBottleneck 相关 issue。'""",
    ),
    "uncached_image_demo.dart": (
        "未缓存图片",
        """\
          '问题：Image.network 未设 cacheWidth/cacheHeight，解码全尺寸图占内存。\\n'
          '修复：按显示尺寸设置缓存宽高，或使用带缓存的图片库。\\n\\n'
          '滚动图库，观察 ImageMemory / uncached_images。'""",
    ),
    "memory_pressure_demo.dart": (
        "内存压力",
        """\
          '问题：大量分配 Dart/原生内存且不释放，触发 GC 与堆增长。\\n'
          '修复：及时释放、避免无界缓存；原生缓冲用完要 free。\\n\\n'
          '点「Dart 堆 +10MB / 原生 +10MB」，需 profile --no-dds 才能看到 GC issue。'""",
    ),
    "keepalive_demo.dart": (
        "KeepAlive 过度使用",
        """\
          '问题：$_tabCount 个 Tab 都用 AutomaticKeepAliveClientMixin，离屏页一直存活。\\n'
          '修复：只对确实需要保活的页开启 keepAlive。\\n\\n'
          '来回切 Tab，观察 excessive_keep_alive。'""",
    ),
    "network_stress_demo.dart": (
        "搜索 + 图库（网络）",
        """\
          '问题：每个按键都发请求（无防抖）；图库拉过大响应。\\n'
          '修复：搜索防抖/取消上一次请求；分页与压缩响应。\\n\\n'
          '输入搜索、刷图库，观察 slow_request / request_frequency / large_response。'""",
    ),
    "platform_channel_demo.dart": (
        "Platform Channel 过密",
        """\
          '问题：每秒超过约 20 次平台通道调用会拖慢 UI。\\n'
          '修复：合并请求、降频、批量一次往返。\\n\\n'
          '点「连发 50 次 / 持续负载」，观察 platform_channel_traffic。'""",
    ),
    "font_loading_demo.dart": (
        "字体加载压力",
        """\
          '问题：单页使用 ${_badFonts.length} 种自定义字体，增加加载与首绘成本。\\n'
          '修复：限制 1～2 个字族，用字重/字号变化；必要字体启动时预加载。\\n\\n'
          '切换错误/正确模式，观察 FontLoading 检测。'""",
    ),
    "combined_social_feed_demo.dart": (
        "综合：社交信息流",
        """\
          '问题：顶层 setState 重建全部 $_cardCount 张卡片，并叠加图片/布局反模式。\\n'
          '修复：缩小重建范围，配合懒加载与合理图片缓存。\\n\\n'
          '滚动刷新，观察多 detector 关联结果。'""",
    ),
    "combined_chat_demo.dart": (
        "综合：聊天页",
        """\
          '问题：Timer.periodic 每 2 秒顶层 setState，并叠加 KeepAlive / Channel 压力。\\n'
          '修复：局部刷新、控制保活与通道频率。\\n\\n'
          '停留本页观察组合问题如何同时出现。'""",
    ),
}

APPBAR_ONLY: dict[str, str] = {
    "stream_resource_demo.dart": "Stream 资源泄漏",
    "tracked_resource_demo.dart": "Tracked 资源泄漏",
    "tabbed_shell_demo.dart": "多 Tab Shell",
    "custom_detector_cookbook_demo.dart": "自定义 Detector 教程",
    "shader_jank_demo.dart": None,  # has DemoScaffold; secondary screen below
}

CAPTURE_APPBARS = {
    "HeavyCompute capture helper": "HeavyCompute 采集助手",
    "RebuildActivity capture helper": "RebuildActivity 采集助手",
    "FrameTiming capture helper": "FrameTiming 采集助手",
    "MemoryPressure capture helper": "MemoryPressure 采集助手",
    "NetworkMonitor capture helper": "NetworkMonitor 采集助手",
    "PlatformChannel capture helper": "PlatformChannel 采集助手",
    "Repaint capture helper": "Repaint 采集助手",
    "StreamResource capture helper": "StreamResource 采集助手",
    "Tracked resource capture helper": "TrackedResource 采集助手",
    "Shader-heavy screen": "着色器重屏",
    "Stream Resource Leaks": "Stream 资源泄漏",
    "Tracked Resource Leaks": "Tracked 资源泄漏",
    "Tabbed Shell": "多 Tab Shell",
    "Custom Detector Cookbook": "自定义 Detector 教程",
}

# Common UI chrome replacements (whole-file safe-ish)
UI_REPLACEMENTS = [
    ("Bad Pattern", "错误写法"),
    ("Fixed Pattern", "正确写法"),
    ("Instructions", "说明"),
    ("Bad rebuilds", "错误重建"),
    ("Fixed rebuilds", "正确重建"),
    ("label: 'Built'", "label: '已构建'"),
    ("label: 'Total'", "label: '总计'"),
    ("label: const Text('Tap')", "label: const Text('点击')"),
    ("Non-lazy item", "非懒加载项"),
    ("Built eagerly at startup", "启动时全部构建"),
    ("Lazy item", "懒加载项"),
    ("Built only when visible", "仅可见时构建"),
    ("Rapid Fire (50)", "连发 50 次"),
    ("Single Call", "单次调用"),
    ("Batched Call (50 items, 1 round-trip)", "批量调用（50 项，1 次往返）"),
    ("Simulate EventChannel Stream", "模拟 EventChannel 流"),
    ("Dart Heap +10MB", "Dart 堆 +10MB"),
    ("Native +10MB", "原生 +10MB"),
    ("Release All", "全部释放"),
    ("Animated blur", "动画模糊"),
    # NOTE: do not globally replace Running/Paused — they appear in identifiers.
    ("? 'Running' : 'Paused'", "? '运行中' : '已暂停'"),
    ("Navigate to shader-heavy screen", "进入着色器重屏"),
    ("Option 1: Impeller (recommended)", "方案 1：Impeller（推荐）"),
    ("Option 2: Warm-up frame", "方案 2：暖机帧"),
    ("Trigger slow frame", "触发慢帧"),
    ("Slow API (3 s+ response)", "慢接口（3 秒+）"),
    ("Tooltip Usage Detector", "Tooltip 使用检测"),
    ("Slow Frame Detector", "慢帧检测"),
    ("Raster Hot Spot Detector", "Raster 热点检测"),
]


def replace_scaffold_block(text: str, new_title: str, new_desc_literal: str) -> str:
    """Replace DemoScaffold title + adjacent description string literals."""
    m = re.search(
        r"(DemoScaffold\(\s*title:\s*)'[^']*'(\s*,\s*description:\s*)",
        text,
    )
    if not m:
        return text
    start = m.end()
    # consume adjacent '...' strings until we hit a comma followed by an identifier key
    i = start
    while True:
        while i < len(text) and text[i] in " \t\n":
            i += 1
        if i >= len(text) or text[i] != "'":
            break
        i += 1
        while i < len(text):
            if text[i] == "\\":
                i += 2
                continue
            if text[i] == "'":
                i += 1
                break
            i += 1
        # peek next non-space
        j = i
        while j < len(text) and text[j] in " \t\n":
            j += 1
        if j < len(text) and text[j] == "'":
            i = j
            continue
        break
    # i should be at end of last adjacent string; expect comma next
    new_block = f"{m.group(1)}'{new_title}'{m.group(2)}{new_desc_literal}"
    return text[: m.start()] + new_block + text[i:]


def main() -> None:
    # DemoScaffold chrome
    scaffold = ROOT / "demo_scaffold.dart"
    s = scaffold.read_text()
    for a, b in UI_REPLACEMENTS[:3]:
        s = s.replace(a, b)
    scaffold.write_text(s)

    for fname, (title, desc) in DEMOS.items():
        path = ROOT / fname
        if not path.exists():
            print("missing", fname)
            continue
        text = path.read_text()
        text2 = replace_scaffold_block(text, title, desc)
        if text2 == text:
            print("NO scaffold replace", fname)
        else:
            text = text2
            print("scaffold ok", fname)
        for a, b in UI_REPLACEMENTS:
            text = text.replace(a, b)
        path.write_text(text)

    # AppBar-only demos + secondary titles + capture helpers
    for path in ROOT.glob("*.dart"):
        text = path.read_text()
        orig = text
        for en, zh in CAPTURE_APPBARS.items():
            text = text.replace(f"Text('{en}')", f"Text('{zh}')")
            text = text.replace(f"const Text('{en}')", f"const Text('{zh}')")
        for a, b in UI_REPLACEMENTS:
            text = text.replace(a, b)
        if text != orig:
            path.write_text(text)
            print("ui/appbar", path.name)


if __name__ == "__main__":
    main()
