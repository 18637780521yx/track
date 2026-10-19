/// Build engine/Dart cold-start phase breakdown (scheme A) from Sleuth startup JSON.
List<Map<String, dynamic>> buildColdStartPhases(Map<String, dynamic>? startup) {
  if (startup == null || startup.isEmpty) return const [];

  double? numOf(String key) => (startup[key] as num?)?.toDouble();

  final ttff = numOf('ttffMs');
  final tti = numOf('ttiMs');
  final framework = numOf('frameworkInitMs');
  final frameTotal = numOf('firstFrameTotalMs');
  final vsync = numOf('firstFrameVsyncOverheadMs');
  final build = numOf('firstFrameBuildMs');
  final raster = numOf('firstFrameRasterMs');
  final preDart = numOf('preDartOverheadMs');
  final engineTtff = numOf('engineTtffMs');
  final dominant = startup['dominantPhase']?.toString();
  final dominantPct = numOf('dominantPhasePercent');

  // Residual inside TTFF after framework init + first-frame work.
  double? bootstrap;
  if (ttff != null) {
    final used = (framework ?? 0) + (frameTotal ?? 0);
    bootstrap = (ttff - used).clamp(0, ttff);
  }

  double? ttiGap;
  if (ttff != null && tti != null) {
    ttiGap = tti - ttff; // may be slightly negative due to clock quirks
  }

  final phases = <Map<String, dynamic>>[
    if (preDart != null)
      _phase(
        id: 'pre_dart',
        name: 'Pre-Dart',
        ms: preDart,
        group: 'engine',
        note: '引擎入口 → Dart 入口（业务难改）',
      ),
    if (framework != null)
      _phase(
        id: 'framework_init',
        name: 'Framework init',
        ms: framework,
        group: 'ttff',
        note: 'WidgetsFlutterBinding.ensureInitialized',
      ),
    if (bootstrap != null)
      _phase(
        id: 'app_bootstrap',
        name: '业务启动',
        ms: bootstrap,
        group: 'ttff',
        note: 'init 之后 → 首帧之前（API/DI/路由等）',
        highlight: true,
      ),
    if (vsync != null)
      _phase(
        id: 'first_frame_vsync',
        name: '首帧 · vsync',
        ms: vsync,
        group: 'ttff',
        note: '第一帧调度开销',
      ),
    if (build != null)
      _phase(
        id: 'first_frame_build',
        name: '首帧 · build',
        ms: build,
        group: 'ttff',
        note: '第一帧构建',
      ),
    if (raster != null)
      _phase(
        id: 'first_frame_raster',
        name: '首帧 · raster',
        ms: raster,
        group: 'ttff',
        note: '第一帧光栅化',
      ),
    if (ttff != null)
      _phase(
        id: 'ttff',
        name: 'TTFF（合计）',
        ms: ttff,
        group: 'total',
        note: 'Dart 入口 → 首帧完成',
        isTotal: true,
      ),
    if (ttiGap != null)
      _phase(
        id: 'tti_gap',
        name: '可交互等待',
        ms: ttiGap < 0 ? 0 : ttiGap,
        group: 'post',
        note: ttiGap < 0
            ? 'TTI 略早于 TTFF（时钟误差），按 0 计'
            : 'TTFF → markInteractive',
        rawMs: ttiGap,
      ),
    if (tti != null)
      _phase(
        id: 'tti',
        name: 'TTI（合计）',
        ms: tti,
        group: 'total',
        note: 'Dart 入口 → 可交互',
        isTotal: true,
      ),
    if (engineTtff != null)
      _phase(
        id: 'engine_ttff',
        name: 'Engine TTFF',
        ms: engineTtff,
        group: 'engine',
        note: '引擎入口 → 首帧（含 Pre-Dart）',
        isTotal: true,
      ),
  ];

  // Percent of TTFF for phases that belong to the TTFF budget.
  if (ttff != null && ttff > 0) {
    for (final p in phases) {
      if (p['group'] == 'ttff') {
        final ms = (p['ms'] as num).toDouble();
        p['pctOfTtff'] = double.parse(((ms / ttff) * 100).toStringAsFixed(1));
      }
    }
  }

  if (dominant != null) {
    for (final p in phases) {
      if (p['id'] == 'ttff') {
        p['dominantPhase'] = dominant;
        if (dominantPct != null) p['dominantPhasePercent'] = dominantPct;
      }
    }
  }

  return phases;
}

Map<String, dynamic> _phase({
  required String id,
  required String name,
  required double ms,
  required String group,
  required String note,
  bool highlight = false,
  bool isTotal = false,
  double? rawMs,
}) =>
    {
      'id': id,
      'name': name,
      'ms': double.parse(ms.toStringAsFixed(1)),
      'group': group,
      'note': note,
      if (highlight) 'highlight': true,
      if (isTotal) 'isTotal': true,
      if (rawMs != null) 'rawMs': double.parse(rawMs.toStringAsFixed(1)),
    };
