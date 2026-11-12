import { EventRecord } from '../api/client';

/** 报告相关埋点 */
export const REPORT_EVENTS = [
  'app_lifecycle',
  'app_page',
  'app_transition',
  'app_network',
  'ui_tap',
  'ui_scroll',
  'perf_mcp_step',
  'app_crash',
  'app_error',
  'app_anr',
  'app_jank',
  'app_memory_leak',
  'perf_slow_request',
  'perf_large_response',
  'perf_http_error',
  'perf_jank',
  'perf_memory_increase',
  'perf_memory_leak',
  'perf_transition_leak',
  'perf_slow_cold_start',
  'perf_route_breadcrumb',
] as const;

const ALERT_NAMES = new Set([
  'app_crash',
  'app_error',
  'app_anr',
  'app_jank',
  'app_memory_leak',
  'perf_slow_request',
  'perf_large_response',
  'perf_http_error',
  'perf_jank',
  'perf_memory_increase',
  'perf_memory_leak',
  'perf_transition_leak',
  'perf_slow_cold_start',
]);

export type ModuleKind = 'lifecycle' | 'page' | 'transition';

export type TimelineEventType =
  | 'cold_start'
  | 'lifecycle'
  | 'action'
  | 'network'
  | 'navigate'
  | 'alert'
  | 'mcp';

export interface TimelineEvent {
  id: string;
  type: TimelineEventType;
  at: string;
  label: string;
  ok: boolean;
  source?: 'mcp' | 'manual';
  route?: string;
  ms?: number;
  detail?: Record<string, unknown>;
  memoryLevel?: 'trend' | 'pressure' | 'retained' | 'gc' | 'resource';
}

export interface TimelineSegment {
  id: string;
  module: ModuleKind;
  title: string;
  at: string;
  events: TimelineEvent[];
  kind?: string;
  route?: string;
  from?: string;
  to?: string;
  transitionKind?: string;
  /** 离开本页时的转场（内联在页卡末尾，不再单独成卡） */
  exitTo?: string;
  exitKind?: string;
  exitFrom?: string;
  /** 弹层：出现 / 消失（由 kind 或 from/to 推断） */
  modalPhase?: 'open' | 'close';
  ttffMs?: number;
  ttiMs?: number;
  /** 冷启动分阶段（Pre-Dart / Framework / 业务启动 / 首帧 / TTFF / TTI） */
  startupPhases?: StartupPhase[];
  actionCount: number;
  networkCount: number;
  alertCount: number;
  leakHint?: string;
}

/** 路由壳：`/tabs#work` → `/tabs` */
export function routeShell(route?: string | null): string {
  if (!route) return '';
  return route.split('#')[0] || route;
}

/** 裸壳升成带 tab 的逻辑路由：`/tabs` → `/tabs#work` */
export function isShellRouteUpgrade(from?: string | null, to?: string | null): boolean {
  if (!from || !to || from === to) return false;
  return !from.includes('#') && to.includes('#') && routeShell(from) === routeShell(to);
}

/** 弹层出现/消失：新 kind 优先，旧 modal_* 用 from/to 推断 */
export function inferModalPhase(
  kind?: string,
  from?: string,
  to?: string,
): 'open' | 'close' | undefined {
  const k = (kind || '').toLowerCase();
  if (k.endsWith('_open') && k.startsWith('modal_')) return 'open';
  if (k.endsWith('_close') && k.startsWith('modal_')) return 'close';
  const fromModal =
    !!from && (from.startsWith('#modal/') || from.includes('#modal/'));
  const toModal = !!to && (to.startsWith('#modal/') || to.includes('#modal/'));
  if (toModal && !fromModal) return 'open';
  if (fromModal && !toModal) return 'close';
  if (k.startsWith('modal_')) {
    if (toModal) return 'open';
    if (fromModal) return 'close';
  }
  return undefined;
}

export interface StartupPhase {
  id: string;
  name: string;
  ms: number;
  note?: string;
  pctOfTtff?: number;
  isTotal?: boolean;
  highlight?: boolean;
}

export interface SessionReport {
  sessionId: string;
  anonymousId: string;
  distinctId?: string | null;
  /** common_properties.device_udid */
  deviceUdid: string;
  deviceModel: string;
  deviceBrand: string;
  deviceOs: string;
  appVersion: string;
  appName: string;
  /** 列表主标题：用户标识优先，否则设备 */
  userLabel: string;
  /** 列表副标题：设备型号等 */
  deviceLabel: string;
  title: string;
  startAt: string;
  endAt: string;
  durationMs: number;
  events: EventRecord[];
  segments: TimelineSegment[];
  stepCount: number;
  alertCount: number;
  networkCount: number;
  actionCount: number;
  avgFps?: number;
  rssPeakMb?: number;
  pages: string[];
}

function prop(e: EventRecord, key: string): unknown {
  return e.properties?.[key];
}

function propStr(e: EventRecord, key: string): string {
  const v = prop(e, key);
  return v == null || v === '' ? '' : String(v);
}

function propNum(e: EventRecord, key: string): number | undefined {
  const v = prop(e, key);
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  if (typeof v === 'string' && v.trim() !== '' && !Number.isNaN(Number(v))) {
    return Number(v);
  }
  return undefined;
}

function isAlert(name: string): boolean {
  return ALERT_NAMES.has(name) || name.startsWith('perf_');
}

function lifecycleTitle(kind: string): string {
  switch (kind) {
    case 'cold_start':
    case 'first_open':
      return 'App 启动';
    case 'background':
    case 'paused':
    case 'hidden':
      return 'App 进入后台';
    case 'foreground':
    case 'resumed':
      return 'App 进入前台';
    default:
      return kind || '生命周期';
  }
}

/** 图标字体 / PUA / 网络 ErrorWidget 文案，不当作有效点击名 */
function isUsableLabel(s: string): boolean {
  const t = s.trim();
  if (!t) return false;
  const lower = t.toLowerCase();
  if (
    lower.includes('httpexception') ||
    lower.includes('socketexception') ||
    lower.includes('invalid statuscode') ||
    lower.includes('statuscode:') ||
    t.includes('uri = http') ||
    lower.startsWith('exception:') ||
    lower.startsWith('error:') ||
    t.startsWith('http://') ||
    t.startsWith('https://') ||
    (t.length > 64 && (lower.includes('https://') || lower.includes('http://')))
  ) {
    return false;
  }
  for (const ch of t) {
    const c = ch.codePointAt(0)!;
    if (c <= 0x1f || c === 0x7f) continue;
    if (c >= 0xe000 && c <= 0xf8ff) continue;
    if (c >= 0xf0000 && c <= 0xffffd) continue;
    if (c >= 0x100000 && c <= 0x10fffd) continue;
    return true;
  }
  return false;
}

function actionLabel(e: EventRecord): string {
  if (e.name === 'ui_tap') {
    const candidates = [
      propStr(e, 'displayLabel'),
      propStr(e, 'key'),
      propStr(e, 'text'),
      propStr(e, 'label'),
      propStr(e, 'hint'),
    ];
    const good = candidates.find(isUsableLabel);
    if (good) return good.startsWith('tap:') ? good : `tap:${good}`;
    const wt = propStr(e, 'widgetType');
    const x = propNum(e, 'x');
    const y = propNum(e, 'y');
    if (wt && x != null && y != null) {
      return `tap:${wt}@${Math.round(x)},${Math.round(y)}`;
    }
    if (x != null && y != null) return `tap@${Math.round(x)},${Math.round(y)}`;
    return 'tap';
  }
  if (e.name === 'ui_scroll') {
    const dir = propStr(e, 'direction') || 'scroll';
    const dist = propNum(e, 'distance');
    return dist != null ? `scroll:${dir}${Math.round(dist)}` : `scroll:${dir}`;
  }
  if (e.name === 'perf_mcp_step') {
    const action = propStr(e, 'action') || propStr(e, 'step_id') || 'mcp_step';
    return action;
  }
  return e.name;
}

function alertLabel(e: EventRecord): string {
  if (e.name.startsWith('perf_')) {
    const t = e.name.slice('perf_'.length);
    const msg = propStr(e, 'message');
    if (msg) return `${t} · ${msg}`;
    const ms = propNum(e, 'duration_ms') ?? propNum(e, 'durationMs');
    if (ms != null) return `${t} · ${Math.round(ms)}ms`;
    return t;
  }
  switch (e.name) {
    case 'app_jank': {
      const kind = propStr(e, 'type') || 'jank';
      const ms =
        propNum(e, 'total_ms') ??
        propNum(e, 'max_total_ms') ??
        propNum(e, 'avg_slow_ms') ??
        propNum(e, 'duration_ms');
      const frozen = propNum(e, 'frozen_frames');
      const slow = propNum(e, 'slow_frames');
      const buildSlow = propNum(e, 'build_slow_frames');
      const rasterSlow = propNum(e, 'raster_slow_frames');
      const buildMs = propNum(e, 'build_ms') ?? propNum(e, 'max_build_ms');
      const rasterMs = propNum(e, 'raster_ms') ?? propNum(e, 'max_raster_ms');
      const bits = [kind];
      if (ms != null) bits.push(`${Math.round(ms)}ms`);
      if (frozen) {
        bits.push(`frozen×${frozen}`);
        // 单帧 frozen 带当帧 build/raster；窗口聚合用峰值
        if (buildMs != null || rasterMs != null) {
          const phases: string[] = [];
          if (buildMs != null) phases.push(`build ${Math.round(buildMs)}ms`);
          if (rasterMs != null) phases.push(`raster ${Math.round(rasterMs)}ms`);
          bits.push(phases.join(' / '));
        }
      } else if ((buildSlow && buildSlow > 0) || (rasterSlow && rasterSlow > 0)) {
        const phases: string[] = [];
        if (buildSlow && buildSlow > 0) phases.push(`build×${buildSlow}`);
        if (rasterSlow && rasterSlow > 0) phases.push(`raster×${rasterSlow}`);
        bits.push(phases.join(' '));
      } else if (slow) {
        bits.push(`slow×${slow}`);
      }
      return bits.join(' · ');
    }
    case 'app_memory_leak': {
      const type = propStr(e, 'type') || 'memory';
      const rss = propNum(e, 'rss_mb');
      if (type === 'memory_pressure') {
        return rss != null ? `内存占用偏高 · RSS ${rss.toFixed(1)} MB（非泄漏结论）` : '内存占用偏高';
      }
      if (['memory_growth', 'heap_growing', 'heap_retained_growth', 'native_memory_growing'].includes(type)) {
        const growth = propNum(e, 'growth_bytes');
        const window = propNum(e, 'window_ms');
        const titles: Record<string, string> = {
          memory_growth: '进程内存增长趋势', heap_growing: 'Dart 堆增长趋势',
          heap_retained_growth: '完整 GC 后堆底线增长', native_memory_growing: 'RSS 残差增长（估算）',
        };
        const rate = propNum(e, 'growth_rate_bytes_per_sec');
        return [`${titles[type]}（未确认泄漏）`,
          growth != null ? `窗口增长 ${(growth / 1048576).toFixed(1)} MB` : '增长量未知',
          rate != null ? `${(rate / 1024).toFixed(1)} KB/s` : '',
          rss != null ? `RSS ${rss.toFixed(1)} MB` : '',
          window != null ? `采样窗口 ${Math.round(window / 1000)} 秒` : '',
        ].filter(Boolean).join(' · ');
      }
      if (type === 'gc_pressure') {
        return `GC 频繁 · ${propNum(e, 'gc_count') ?? '?'} 次 / 10 秒（非泄漏结论）`;
      }
      if (type === 'stream_resource_growth') {
        return `异步资源数量增长 · ${propStr(e, 'resource_class')} · 新增 ${propNum(e, 'instance_delta') ?? '?'} 个（疑似滞留）`;
      }
      return propStr(e, 'message') || (rss != null ? `${type} · ${rss.toFixed(1)} MB` : type);
    }
    case 'app_crash':
      return `crash · ${propStr(e, 'exception_type') || propStr(e, 'message') || 'fatal'}`;
    case 'app_error':
      return `error · ${propStr(e, 'exception_type') || propStr(e, 'message') || 'error'}`;
    case 'app_anr':
      return `anr · ${propStr(e, 'blocked_ms') ? `${prop(e, 'blocked_ms')}ms` : propStr(e, 'anr_source') || 'blocked'}`;
    default:
      return e.name;
  }
}

function commonStr(e: EventRecord, key: string): string {
  const v = e.common_properties?.[key];
  return v == null || v === '' ? '' : String(v);
}

function eventSource(e: EventRecord): 'mcp' | 'manual' | undefined {
  const s = propStr(e, 'source');
  if (s === 'mcp' || s === 'manual') return s;
  if (e.name === 'perf_mcp_step') return 'mcp';
  if (e.name === 'ui_tap' || e.name === 'ui_scroll') return 'manual';
  return undefined;
}

function readStartupPhases(e: EventRecord): StartupPhase[] {
  const raw = prop(e, 'startup_phases') ?? prop(e, 'startupPhases');
  if (!Array.isArray(raw)) return [];
  const out: StartupPhase[] = [];
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue;
    const p = item as Record<string, unknown>;
    const name = p.name == null ? '' : String(p.name);
    const ms = typeof p.ms === 'number' ? p.ms : Number(p.ms);
    if (!name || !Number.isFinite(ms)) continue;
    out.push({
      id: p.id == null ? name : String(p.id),
      name,
      ms,
      note: p.note == null || p.note === '' ? undefined : String(p.note),
      pctOfTtff:
        typeof p.pctOfTtff === 'number'
          ? p.pctOfTtff
          : p.pctOfTtff != null && Number.isFinite(Number(p.pctOfTtff))
            ? Number(p.pctOfTtff)
            : undefined,
      isTotal: p.isTotal === true,
      highlight: p.highlight === true,
    });
  }
  return out;
}

/** App 启动应居首；丢掉启动前空的噪声页（如 `/`）。 */
function finalizeColdStartOrder(segments: TimelineSegment[]): TimelineSegment[] {
  const coldIdx = segments.findIndex(
    (s) => s.module === 'lifecycle' && (s.kind === 'cold_start' || s.kind === 'first_open'),
  );
  if (coldIdx < 0) return segments;
  const cold = segments[coldIdx];
  const before = segments.slice(0, coldIdx);
  const after = segments.slice(coldIdx + 1);
  const keptBefore = before.filter(
    (s) => !(s.module === 'page' && s.events.length === 0),
  );
  return [...keptBefore, cold, ...after];
}

/**
 * 去掉「空落地页 → 转场到同路由 → 再一张同路由页」里的空页；
 * 以及相邻同路由空页。
 */
function coalesceDuplicatePages(segments: TimelineSegment[]): TimelineSegment[] {
  const out: TimelineSegment[] = [];
  for (let i = 0; i < segments.length; i++) {
    const s = segments[i];
    const next = segments[i + 1];
    // `/tabs`（可含告警）+ `/tabs#work` → 事件并入逻辑 Tab，丢掉裸壳页卡
    if (
      s.module === 'page' &&
      s.route &&
      next?.module === 'page' &&
      next.route &&
      isShellRouteUpgrade(s.route, next.route)
    ) {
      next.events = [...s.events, ...next.events].sort(
        (a, b) => new Date(a.at).getTime() - new Date(b.at).getTime(),
      );
      next.at = s.at;
      recount(next);
      continue;
    }
    if (s.module === 'page' && s.events.length === 0 && s.route) {
      const next2 = segments[i + 2];
      // 空页 + 转场(to=此路由) → 丢空页（后面会有落地页）
      if (next?.module === 'transition' && next.to === s.route) {
        continue;
      }
      // 空页 + 同路由页 → 丢空页
      if (next?.module === 'page' && next.route === s.route) {
        continue;
      }
      // 空页夹在冷启动与同路由转场之间已在上面覆盖；冷启动后仅空页且后面无内容则保留到 merge
      if (
        next?.module === 'transition' &&
        next2?.module === 'page' &&
        next2.route === s.route
      ) {
        continue;
      }
    }
    out.push(s);
  }
  return out;
}

function emptyPage(route: string, at: string, id: string): TimelineSegment {
  return {
    id,
    module: 'page',
    title: route || '（无路由）',
    at,
    route: route || undefined,
    events: [],
    actionCount: 0,
    networkCount: 0,
    alertCount: 0,
  };
}

function recount(seg: TimelineSegment) {
  seg.actionCount = seg.events.filter((e) => e.type === 'action' || e.type === 'mcp').length;
  seg.networkCount = seg.events.filter((e) => e.type === 'network').length;
  seg.alertCount = seg.events.filter((e) => e.type === 'alert' || !e.ok).length;
}

/** 从埋点按时间重建页面级时间线（对齐 MCP HTML report v4） */
export function buildSegments(records: EventRecord[]): TimelineSegment[] {
  const seen = new Set<string>();
  const sorted = records.filter((event) => {
    if (!event.event_id) return true;
    if (seen.has(event.event_id)) return false;
    seen.add(event.event_id);
    return true;
  }).sort(
    (a, b) => new Date(a.event_time).getTime() - new Date(b.event_time).getTime(),
  );
  const segments: TimelineSegment[] = [];
  let currentPage: TimelineSegment | null = null;
  let lastTransition: TimelineSegment | null = null;
  let seq = 0;

  const flushPage = () => {
    if (!currentPage) return;
    recount(currentPage);
    segments.push(currentPage);
    currentPage = null;
  };

  const upgradeShellRefs = (bare: string, enriched: string) => {
    if (lastTransition?.to && isShellRouteUpgrade(lastTransition.to, enriched)) {
      lastTransition.to = enriched;
      lastTransition.title = `${lastTransition.from || '?'} → ${enriched}`;
    }
    for (let i = segments.length - 1; i >= 0; i--) {
      const s = segments[i];
      if (s.module === 'page' && s.exitTo && isShellRouteUpgrade(s.exitTo, enriched)) {
        s.exitTo = enriched;
        break;
      }
      if (s.module === 'page' && s.route === bare) break;
    }
  };

  const ensurePage = (route: string, at: string) => {
    if (currentPage && (currentPage.route === route || !route)) return currentPage;
    // `/tabs` 空壳 → `/tabs#work`：原地升级，不新开页卡
    if (currentPage?.route && route && isShellRouteUpgrade(currentPage.route, route)) {
      const bare = currentPage.route;
      currentPage.route = route;
      currentPage.title = route;
      upgradeShellRefs(bare, route);
      return currentPage;
    }
    // 已是 `/tabs#work`，后续裸 `/tabs` 忽略
    if (currentPage?.route && route && isShellRouteUpgrade(route, currentPage.route)) {
      return currentPage;
    }
    flushPage();
    currentPage = emptyPage(route, at, `seg_${seq++}`);
    lastTransition = null;
    return currentPage;
  };

  for (const e of sorted) {
    const at = e.event_time;
    const route = propStr(e, 'route');

    if (e.name === 'app_lifecycle') {
      const kind = propStr(e, 'kind') || 'lifecycle';
      const isCold = kind === 'cold_start' || kind === 'first_open';
      const phases = isCold ? readStartupPhases(e) : [];
      const phaseEvents: TimelineEvent[] = phases.map((p, i) => ({
        id: `${e.event_id}_phase_${p.id || i}`,
        type: 'cold_start' as const,
        at,
        label: p.name,
        ok: true,
        ms: p.ms,
        detail: {
          phaseId: p.id,
          note: p.note,
          pctOfTtff: p.pctOfTtff,
          isTotal: p.isTotal,
          highlight: p.highlight,
        },
      }));
      const lifeSeg: TimelineSegment = {
        id: `seg_${seq++}`,
        module: 'lifecycle',
        title: lifecycleTitle(kind),
        at,
        kind,
        route: route || undefined,
        events:
          phaseEvents.length > 0
            ? phaseEvents
            : [
                {
                  id: e.event_id,
                  type: isCold ? 'cold_start' : 'lifecycle',
                  at,
                  label: lifecycleTitle(kind),
                  ok: true,
                  route: route || undefined,
                  detail: e.properties,
                },
              ],
        ttffMs: propNum(e, 'ttff_ms') ?? propNum(e, 'ttffMs'),
        ttiMs: propNum(e, 'tti_ms') ?? propNum(e, 'ttiMs'),
        startupPhases: phases.length ? phases : undefined,
        actionCount: 0,
        networkCount: 0,
        alertCount: 0,
      };

      // 冷启动常晚于首屏 route 观察：丢掉启动前空页，把同路由落地页挪到启动后
      if (isCold) {
        let landing: TimelineSegment | null = null;
        if (currentPage && currentPage.events.length === 0) {
          if (!route || !currentPage.route || currentPage.route === route) {
            landing = currentPage;
          }
          currentPage = null;
        }
        // 丢掉已入列的启动前空页
        while (segments.length) {
          const last = segments[segments.length - 1];
          if (last.module === 'page' && last.events.length === 0) {
            const orphan = segments.pop()!;
            if (
              !landing &&
              route &&
              orphan.route === route
            ) {
              landing = orphan;
            }
            continue;
          }
          break;
        }
        flushPage();
        lastTransition = null;
        segments.push(lifeSeg);
        if (landing) {
          currentPage = landing;
        } else if (route) {
          currentPage = emptyPage(route, at, `seg_${seq++}`);
        }
      } else {
        flushPage();
        lastTransition = null;
        segments.push(lifeSeg);
      }
      continue;
    }

    if (e.name === 'app_transition') {
      let from = propStr(e, 'from');
      const to = propStr(e, 'to');
      // GetX 占位 `/`：用当前页路由修正 modal/转场 from
      if ((!from || from === '/') && currentPage?.route) {
        from = currentPage.route;
      }
      // GetX 竞态：from===to（如 email→email）。若当前页已是来源业务页，用它修正 from；
      // 否则忽略这条自环转场，避免多出一张空目标页卡。
      if (from && to && from === to) {
        if (
          currentPage?.route &&
          currentPage.route !== to &&
          currentPage.route !== '/'
        ) {
          from = currentPage.route;
        } else {
          if (!currentPage) currentPage = emptyPage(to, at, `seg_${seq++}`);
          continue;
        }
      }
      // 首屏 seed：/tabs → /tabs#work 且当前已是空落地页 → 不单独成转场，避免双页卡
      const softTabSeed =
        propStr(e, 'kind') === 'tab_change' &&
        from === '/tabs' &&
        !!to &&
        currentPage != null &&
        currentPage.events.length === 0 &&
        (currentPage.route === to || !currentPage.route);
      if (softTabSeed) {
        if (currentPage && !currentPage.route && to) {
          currentPage.route = to;
          currentPage.title = to;
        }
        continue;
      }

      const tKind = propStr(e, 'kind') || 'route_change';
      // Get.offAllNamed：push(tabs) 后紧跟 remove(login)——清栈，不是二次跳转
      if (
        (tKind === 'remove' || tKind === 'stack_clear') &&
        lastTransition &&
        (lastTransition.transitionKind === 'push' ||
          lastTransition.transitionKind === 'replace') &&
        to &&
        lastTransition.to === to &&
        Math.abs(new Date(at).getTime() - new Date(lastTransition.at).getTime()) <
          2000
      ) {
        continue;
      }

      // 当前空页已是转场目标：复用；否则把转场挂到离开页末尾（不再单独成卡）
      let reusePage: TimelineSegment | null = null;
      let sourcePage: TimelineSegment | null = null;
      if (currentPage) {
        if (
          currentPage.events.length === 0 &&
          to &&
          currentPage.route === to
        ) {
          reusePage = currentPage;
          currentPage = null;
        } else if (
          currentPage.events.length === 0 &&
          from &&
          currentPage.route === from
        ) {
          sourcePage = currentPage;
          currentPage = null;
        } else {
          sourcePage = currentPage;
          currentPage = null;
        }
      }
      if (!sourcePage) {
        for (let i = segments.length - 1; i >= 0; i--) {
          const s = segments[i];
          if (s.module !== 'page') {
            if (s.module === 'lifecycle') break;
            continue;
          }
          if (!from || s.route === from || isShellRouteUpgrade(from, s.route || '')) {
            sourcePage = s;
            break;
          }
        }
      }

      const modalPhase = inferModalPhase(tKind, from || undefined, to || undefined);
      if (sourcePage) {
        sourcePage.exitFrom = from || sourcePage.route || undefined;
        sourcePage.exitTo = to || undefined;
        sourcePage.exitKind = tKind;
        sourcePage.modalPhase = modalPhase;
        if (!segments.includes(sourcePage)) {
          recount(sourcePage);
          segments.push(sourcePage);
        }
      }

      lastTransition = {
        id: `exit_${e.event_id}`,
        module: 'transition',
        title: `${from || '?'} → ${to || '?'}`,
        at,
        from: from || undefined,
        to: to || undefined,
        transitionKind: tKind,
        modalPhase,
        events: [],
        actionCount: 0,
        networkCount: 0,
        alertCount: 0,
      };
      if (reusePage) {
        currentPage = reusePage;
      } else if (to) {
        currentPage = emptyPage(to, at, `seg_${seq++}`);
      }
      continue;
    }

    if (e.name === 'app_page') {
      const pageRoute = route || propStr(e, 'route');
      if (!currentPage || currentPage.route !== pageRoute) {
        // 转场已预开同路由页卡时复用
        if (!(currentPage && currentPage.route === pageRoute)) {
          ensurePage(pageRoute, at);
        }
      }
      continue;
    }

    if (e.name === 'ui_tap' || e.name === 'ui_scroll' || e.name === 'perf_mcp_step') {
      const durationMs = propNum(e, 'duration_ms') ?? 0;
      const gestureAtMs = new Date(at).getTime() - Math.max(0, durationMs);
      // 用按下时刻排序，保证「tap → 转场」叙事（上报常晚于 modal push）
      const actionAt = new Date(gestureAtMs).toISOString();
      const actionEv: TimelineEvent = {
        id: e.event_id,
        type: e.name === 'perf_mcp_step' ? 'mcp' : 'action',
        at: actionAt,
        label: actionLabel(e),
        ok: prop(e, 'ok') !== false,
        source: eventSource(e),
        route: route || undefined,
        ms: durationMs > 0 ? durationMs : propNum(e, 'duration_ms'),
        detail: e.properties,
      };

      // Tab onTap 会先改 index 再打转场，ui_tap.route 常已是目标页。
      // 手势早于转场时：强制挂回离开页（exitTo / from），不要用目标路由开新卡。
      const routeAfter = propStr(e, 'route_after');
      let preferRoute = route || currentPage?.route || '';
      if (
        lastTransition &&
        gestureAtMs <= new Date(lastTransition.at).getTime() + 80
      ) {
        const exitTo = lastTransition.to || '';
        const exitFrom = lastTransition.from || '';
        // route 已被改成 to（或等于 route_after）→ 用 from
        if (
          preferRoute &&
          exitTo &&
          (preferRoute === exitTo ||
            isShellRouteUpgrade(preferRoute, exitTo) ||
            preferRoute === routeAfter)
        ) {
          preferRoute = exitFrom || preferRoute;
        }

        let pageIdx = -1;
        // 1) 优先：刚写下 exitTo 的来源页
        for (let i = segments.length - 1; i >= 0; i--) {
          const s = segments[i];
          if (s.module !== 'page') {
            if (s.module === 'lifecycle') break;
            continue;
          }
          if (s.exitTo && (!exitTo || s.exitTo === exitTo)) {
            pageIdx = i;
            break;
          }
        }
        // 2) 其次：route === from
        if (pageIdx < 0 && exitFrom) {
          for (let i = segments.length - 1; i >= 0; i--) {
            const s = segments[i];
            if (s.module !== 'page') continue;
            if (
              s.route === exitFrom ||
              isShellRouteUpgrade(exitFrom, s.route || '')
            ) {
              pageIdx = i;
              break;
            }
          }
        }
        if (pageIdx < 0 && preferRoute && preferRoute !== exitTo) {
          const page = emptyPage(preferRoute, actionAt, `seg_${seq++}`);
          page.exitTo = exitTo || undefined;
          page.exitKind = lastTransition.transitionKind;
          page.exitFrom = preferRoute;
          segments.push(page);
          pageIdx = segments.length - 1;
        }
        if (pageIdx >= 0) {
          const page = segments[pageIdx];
          actionEv.route = page.route || exitFrom || actionEv.route;
          page.events.push(actionEv);
          page.events.sort(
            (a, b) => new Date(a.at).getTime() - new Date(b.at).getTime(),
          );
          recount(page);
          continue;
        }
      }

      const page = ensurePage(preferRoute, actionAt);
      actionEv.route = actionEv.route || page.route;
      page.events.push(actionEv);
      continue;
    }

    if (e.name === 'app_network') {
      const method = propStr(e, 'method') || propStr(e, 'action').replace(/^network:/, '') || 'HTTP';
      const path = propStr(e, 'path') || propStr(e, 'url') || '';
      const status = propNum(e, 'statusCode') ?? propNum(e, 'status_code');
      const preferRoute = route || currentPage?.route || '';
      const target = currentPage?.route === preferRoute || !preferRoute
        ? (currentPage ?? ensurePage(preferRoute, at))
        : ensurePage(preferRoute, at);
      // 请求完成晚于转场时：若 route 仍是旧页，但当前已是新页，挂当前页
      const page =
        currentPage &&
        preferRoute &&
        currentPage.route &&
        currentPage.route !== preferRoute &&
        lastTransition &&
        lastTransition.to === currentPage.route &&
        new Date(at).getTime() >= new Date(lastTransition.at).getTime()
          ? currentPage
          : target;
      const statusBit = status != null ? ` · HTTP ${status}` : '';
      page.events.push({
        id: e.event_id,
        type: 'network',
        at,
        label: path ? `${method} ${path}${statusBit}` : `${method}${statusBit}`,
        ok: status == null || (status >= 0 && status < 400),
        route: page.route || preferRoute || undefined,
        ms: propNum(e, 'durationMs') ?? propNum(e, 'duration_ms'),
        detail: e.properties,
      });
      continue;
    }

    if (isAlert(e.name)) {
      const alertEv: TimelineEvent = {
        id: e.event_id,
        type: 'alert',
        at,
        label: alertLabel(e),
        ok: false,
        memoryLevel: e.name === 'app_memory_leak'
          ? (propStr(e, 'type') === 'memory_pressure' ? 'pressure'
            : propStr(e, 'type') === 'gc_pressure' ? 'gc'
            : propStr(e, 'type') === 'stream_resource_growth' ? 'resource'
            : ['heap_retained_growth', 'memory_leak', 'transition_memory_leak'].includes(propStr(e, 'type')) ? 'retained' : 'trend')
          : e.name === 'perf_transition_leak' || e.name === 'perf_memory_leak' ? 'retained' : undefined,
        route: route || undefined,
        ms: propNum(e, 'duration_ms') ?? propNum(e, 'durationMs'),
        detail: e.properties,
      };
      // 慢/错/大：优先只挂告警；若尚无对应 app_network 行则补一条（兼容旧数据）
      if (e.name === 'perf_slow_request' || e.name === 'perf_http_error' || e.name === 'perf_large_response') {
        const method = propStr(e, 'method') || propStr(e, 'action').replace(/^network:/, '') || 'HTTP';
        const path = propStr(e, 'path') || propStr(e, 'url') || '';
        const status = propNum(e, 'statusCode') ?? propNum(e, 'status_code');
        const target = currentPage ?? (() => {
          const p = ensurePage(route, at);
          return p;
        })();
        const atMs = new Date(at).getTime();
        const hasNet = target.events.some(
          (ev) =>
            ev.type === 'network' &&
            Math.abs(new Date(ev.at).getTime() - atMs) < 5000 &&
            (path ? ev.label.includes(path) : true),
        );
        if (!hasNet) {
          const statusBit = status != null ? ` · HTTP ${status}` : '';
          target.events.push({
            id: `${e.event_id}_net`,
            type: 'network',
            at,
            label: path ? `${method} ${path}${statusBit}` : `${method}${statusBit}`,
            ok: e.name !== 'perf_http_error' && (status == null || status < 400),
            route: route || undefined,
            ms: propNum(e, 'durationMs') ?? propNum(e, 'duration_ms'),
            detail: e.properties,
          });
        }
        target.events.push(alertEv);
        continue;
      }

      // 转场泄漏类优先挂到刚离开的页卡
      if (
        (e.name === 'perf_transition_leak' || e.name === 'perf_memory_leak' ||
          (e.name === 'app_memory_leak' && alertEv.memoryLevel === 'retained' &&
            !propStr(e, 'observation_scope'))) &&
        lastTransition
      ) {
        let exitPage: TimelineSegment | null = null;
        for (let i = segments.length - 1; i >= 0; i--) {
          const s = segments[i];
          if (s.module === 'page' && s.exitTo) {
            exitPage = s;
            break;
          }
        }
        if (exitPage) {
          exitPage.events.push(alertEv);
          if (!exitPage.leakHint) exitPage.leakHint = alertEv.label;
          recount(exitPage);
          continue;
        }
      }

      // 慢冷启动挂到最近的 App 启动段
      if (e.name === 'perf_slow_cold_start') {
        const cold = [...segments]
          .reverse()
          .find(
            (s) =>
              s.module === 'lifecycle' &&
              (s.kind === 'cold_start' || s.kind === 'first_open'),
          );
        if (cold) {
          cold.events.push(alertEv);
          recount(cold);
          continue;
        }
      }

      if (currentPage) {
        currentPage.events.push(alertEv);
      } else if (lastTransition) {
        lastTransition.events.push(alertEv);
      } else {
        const page = ensurePage(route, at);
        page.events.push(alertEv);
      }
      continue;
    }
  }

  flushPage();
  for (const s of segments) recount(s);
  const result = coalesceDuplicatePages(finalizeColdStartOrder(segments));
  for (const segment of result) {
    const groups = new Map<string, TimelineEvent>();
    segment.events = segment.events.filter((event) => {
      if (!event.memoryLevel || (event.memoryLevel === 'retained' && !event.detail?.episode_id)) return true;
      const episode = String(event.detail?.episode_id || 'legacy');
      const key = `${event.memoryLevel}:${event.detail?.type || ''}:${event.detail?.resource_class || ''}:${episode}:${event.route || segment.route || ''}`;
      const previous = groups.get(key);
      const end = String(previous?.detail?.last_seen_at || previous?.at || '');
      const gap = Date.parse(event.at) - Date.parse(end);
      // Only combine nearby signals within the same page visit and route.
      if (!previous || !Number.isFinite(gap) || gap < 0 || gap > 10 * 60 * 1000) {
        event.detail = { ...event.detail, occurrence_count: 1, first_seen_at: event.at, last_seen_at: event.at,
          peak_rss_mb: event.detail?.rss_mb };
        groups.set(key, event);
        return true;
      }
      const count = Number(previous.detail?.occurrence_count || 1) + 1;
      const peak = Math.max(Number(previous.detail?.peak_rss_mb || 0), Number(event.detail?.rss_mb || 0));
      previous.label = `${event.label} · 合并 ${count} 条观测 · 观测跨度 ${Math.round((Date.parse(event.at) - Date.parse(previous.at)) / 1000)} 秒${peak > 0 ? ` · 峰值 RSS ${peak.toFixed(1)} MB` : ''}`;
      previous.detail = { ...previous.detail, occurrence_count: count, last_seen_at: event.at,
        duration_ms: Date.parse(event.at) - Date.parse(previous.at), peak_rss_mb: peak,
        latest_sample: event.detail };
      return false;
    });
    recount(segment);
  }
  return result;
}

export function buildSessionReports(records: EventRecord[]): SessionReport[] {
  const bySession = new Map<string, EventRecord[]>();
  for (const r of records) {
    const sid = (r.session_id || '').trim();
    if (!sid) continue;
    const list = bySession.get(sid);
    if (list) list.push(r);
    else bySession.set(sid, [r]);
  }

  const sessions: SessionReport[] = [];
  for (const [sessionId, events] of bySession) {
    const sorted = [...events].sort(
      (a, b) => new Date(a.event_time).getTime() - new Date(b.event_time).getTime(),
    );
    const segments = buildSegments(sorted);
    const startAt = sorted[0].event_time;
    const endAt = sorted[sorted.length - 1].event_time;
    const pages = segments
      .filter((s) => s.module === 'page' && s.route)
      .map((s) => s.route!);
    const sample = sorted.find((e) => e.common_properties && Object.keys(e.common_properties).length) ?? sorted[0];
    const deviceUdid = commonStr(sample, 'device_udid');
    const deviceModel = commonStr(sample, 'device_model');
    const deviceBrand = commonStr(sample, 'device_brand');
    const deviceOs = [commonStr(sample, 'device_os'), commonStr(sample, 'device_os_version')]
      .filter(Boolean)
      .join(' ');
    const appVersion = commonStr(sample, 'app_version');
    const appName = commonStr(sample, 'app_name');
    const anonymousId = sorted[0]?.anonymous_id ?? '';
    const distinctId = sorted.find((e) => e.distinct_id)?.distinct_id ?? null;
    const userLabel = distinctId || anonymousId || deviceUdid || sessionId.slice(0, 8);
    const deviceLabel = [deviceBrand, deviceModel].filter(Boolean).join(' ') ||
      deviceUdid ||
      deviceOs ||
      '未知设备';
    const testName = sorted.map((e) => propStr(e, 'test_name')).find((t) => t);
    const rssPeak = sorted
      .map((e) => propNum(e, 'rss_mb'))
      .filter((n): n is number => n != null)
      .reduce((a, b) => Math.max(a, b), 0);

    const alertCount = segments.reduce((n, s) => n + s.alertCount, 0);
    const networkCount = segments.reduce((n, s) => n + s.networkCount, 0);
    const actionCount = segments.reduce((n, s) => n + s.actionCount, 0);

    sessions.push({
      sessionId,
      anonymousId,
      distinctId,
      deviceUdid,
      deviceModel,
      deviceBrand,
      deviceOs,
      appVersion,
      appName,
      userLabel,
      deviceLabel,
      title: testName || pages[0] || appName || `会话 ${sessionId.slice(0, 8)}`,
      startAt,
      endAt,
      durationMs: Math.max(0, new Date(endAt).getTime() - new Date(startAt).getTime()),
      events: sorted,
      segments,
      stepCount: segments.length,
      alertCount,
      networkCount,
      actionCount,
      rssPeakMb: rssPeak > 0 ? rssPeak : undefined,
      pages: [...new Set(pages)],
    });
  }

  return sessions.sort(
    (a, b) => new Date(b.startAt).getTime() - new Date(a.startAt).getTime(),
  );
}

export async function fetchReportEvents(
  listEvents: typeof import('../api/client').api.listEvents,
  range: import('../api/client').DateRange,
): Promise<EventRecord[]> {
  const results = await Promise.all(
    REPORT_EVENTS.map((name) => listEvents(range, name, 200, 0)),
  );
  const map = new Map<string, EventRecord>();
  for (const res of results) {
    for (const item of res.items ?? []) {
      map.set(item.event_id, item);
    }
  }
  return [...map.values()];
}
