import { EventRecord } from '../api/client';

/** 报告相关埋点 */
export const REPORT_EVENTS = [
  'app_lifecycle',
  'app_page',
  'app_transition',
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
  ttffMs?: number;
  ttiMs?: number;
  /** 冷启动分阶段（Pre-Dart / Framework / 业务启动 / 首帧 / TTFF / TTI） */
  startupPhases?: StartupPhase[];
  actionCount: number;
  networkCount: number;
  alertCount: number;
  leakHint?: string;
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

/** 图标字体 / PUA 在网页里会显示成 □，不当作有效文案 */
function isUsableLabel(s: string): boolean {
  const t = s.trim();
  if (!t) return false;
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
      const bits = [kind];
      if (ms != null) bits.push(`${Math.round(ms)}ms`);
      if (frozen) bits.push(`frozen×${frozen}`);
      else if (slow) bits.push(`slow×${slow}`);
      return bits.join(' · ');
    }
    case 'app_memory_leak': {
      const type = propStr(e, 'type') || 'memory';
      const rss = propNum(e, 'rss_mb') ?? propNum(e, 'max_rss_mb');
      if (type === 'memory_pressure') {
        return rss != null ? `memory_pressure · RSS ${rss.toFixed(1)} MB` : 'memory_pressure';
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
  const sorted = [...records].sort(
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

  const ensurePage = (route: string, at: string) => {
    if (currentPage && (currentPage.route === route || !route)) return currentPage;
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
      const from = propStr(e, 'from');
      const to = propStr(e, 'to');
      // 首屏 GetX 常打出 / → / 的 push，忽略以免污染路径
      if (from && to && from === to) {
        if (!currentPage) currentPage = emptyPage(to, at, `seg_${seq++}`);
        continue;
      }
      flushPage();
      const tKind = propStr(e, 'kind') || 'route_change';
      const leak =
        tKind === 'remove' && from
          ? `可能存在路由泄漏：${from} 未正确退出`
          : undefined;
      const seg: TimelineSegment = {
        id: `seg_${seq++}`,
        module: 'transition',
        title: `${from || '?'} → ${to || '?'}`,
        at,
        from: from || undefined,
        to: to || undefined,
        transitionKind: tKind,
        leakHint: leak,
        events: [
          {
            id: e.event_id,
            type: 'navigate',
            at,
            label: 'navigate',
            ok: true,
            detail: e.properties,
          },
        ],
        actionCount: 0,
        networkCount: 0,
        alertCount: 0,
      };
      recount(seg);
      segments.push(seg);
      lastTransition = seg;
      if (to) {
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
      const actionEv: TimelineEvent = {
        id: e.event_id,
        type: e.name === 'perf_mcp_step' ? 'mcp' : 'action',
        at,
        label: actionLabel(e),
        ok: prop(e, 'ok') !== false,
        source: eventSource(e),
        route: route || undefined,
        ms: propNum(e, 'duration_ms'),
        detail: e.properties,
      };

      // 手势解析有延迟：若手势开始早于最近转场，应挂回转场前的 from 页
      const durationMs = propNum(e, 'duration_ms') ?? 0;
      const gestureAtMs = new Date(at).getTime() - Math.max(0, durationMs);
      const preferRoute = route || currentPage?.route || '';
      if (
        lastTransition &&
        lastTransition.from &&
        preferRoute &&
        lastTransition.from === preferRoute &&
        gestureAtMs <= new Date(lastTransition.at).getTime()
      ) {
        const tIdx = segments.indexOf(lastTransition);
        let pageIdx = -1;
        if (
          tIdx > 0 &&
          segments[tIdx - 1].module === 'page' &&
          segments[tIdx - 1].route === preferRoute
        ) {
          pageIdx = tIdx - 1;
        } else if (tIdx >= 0) {
          const page = emptyPage(preferRoute, at, `seg_${seq++}`);
          segments.splice(tIdx, 0, page);
          pageIdx = tIdx;
        }
        if (pageIdx >= 0) {
          segments[pageIdx].events.push(actionEv);
          segments[pageIdx].events.sort(
            (a, b) => new Date(a.at).getTime() - new Date(b.at).getTime(),
          );
          recount(segments[pageIdx]);
          continue;
        }
      }

      const page = ensurePage(preferRoute, at);
      actionEv.route = actionEv.route || page.route;
      page.events.push(actionEv);
      continue;
    }

    if (isAlert(e.name)) {
      const alertEv: TimelineEvent = {
        id: e.event_id,
        type: 'alert',
        at,
        label: alertLabel(e),
        ok: false,
        route: route || undefined,
        ms: propNum(e, 'duration_ms') ?? propNum(e, 'durationMs'),
        detail: e.properties,
      };
      // 慢请求等网络类：显示为 network 行 + 内联 alert 更贴近设计；这里统一 alert 行
      if (e.name === 'perf_slow_request' || e.name === 'perf_http_error' || e.name === 'perf_large_response') {
        const method = propStr(e, 'method') || propStr(e, 'action').replace(/^network:/, '') || 'HTTP';
        const path = propStr(e, 'path') || propStr(e, 'url') || '';
        const target = currentPage ?? lastTransition ?? (() => {
          const p = ensurePage(route, at);
          return p;
        })();
        target.events.push({
          id: `${e.event_id}_net`,
          type: 'network',
          at,
          label: path ? `${method} ${path}` : method,
          ok: e.name !== 'perf_http_error',
          route: route || undefined,
          ms: propNum(e, 'durationMs') ?? propNum(e, 'duration_ms'),
          detail: e.properties,
        });
        target.events.push(alertEv);
        continue;
      }

      // 转场泄漏类优先挂转场
      if (
        (e.name === 'perf_transition_leak' || e.name === 'app_memory_leak' || e.name.includes('leak')) &&
        lastTransition &&
        !currentPage?.events.length
      ) {
        lastTransition.events.push(alertEv);
        if (!lastTransition.leakHint) {
          lastTransition.leakHint = alertEv.label;
        }
        continue;
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
  return finalizeColdStartOrder(segments);
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
      .map((e) => propNum(e, 'max_rss_mb') ?? propNum(e, 'rss_mb'))
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
