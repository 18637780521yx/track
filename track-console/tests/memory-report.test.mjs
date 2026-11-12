import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import ts from 'typescript';

// Exercise the production timeline builder without adding a test framework.
const source = await readFile(new URL('../src/report/buildSessionTimeline.ts', import.meta.url), 'utf8');
const { outputText } = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ESNext },
});
const { buildSegments, buildSessionReports } = await import(`data:text/javascript;base64,${Buffer.from(outputText).toString('base64')}`);

function event(id, seconds, properties, name = 'app_memory_leak') {
  const time = new Date(Date.UTC(2026, 10, 12) + seconds * 1000).toISOString();
  return { event_id: id, name, event_time: time, received_at: time,
    anonymous_id: 'test-device', session_id: 'test-session', properties };
}
const page = event('page', 0, { route: '/a' }, 'app_page');
const alerts = (segments) => segments.flatMap(s => s.events).filter(e => e.type === 'alert');
const growth = (id, seconds, extra = {}) => event(id, seconds, {
  route: '/a', type: 'memory_growth', rss_mb: 400, growth_bytes: 10 * 1048576, ...extra,
});

test('RSS totals are not presented as growth amounts', () => {
  const [alert] = alerts(buildSegments([page, growth('g', 10)]));
  assert.match(alert.label, /窗口增长 10\.0 MB/);
  assert.match(alert.label, /RSS 400\.0 MB/);
  assert.match(alert.label, /未确认泄漏/);
});

test('session observed RSS excludes the process lifetime high-water mark', () => {
  const [session] = buildSessionReports([page, growth('g', 10, { max_rss_mb: 999 })]);
  assert.equal(session.rssPeakMb, 400);
  const [withoutCurrent] = buildSessionReports([page,
    event('only-max', 10, { type: 'memory_pressure', max_rss_mb: 999 })]);
  assert.equal(withoutCurrent.rssPeakMb, undefined);
});

test('legacy observations collapse, keeping raw session records and latest evidence', () => {
  const records = [page, growth('g1', 10), growth('g2', 20, { rss_mb: 450 }),
    growth('g3', 30, { rss_mb: 420, growth_bytes: 12 * 1048576 })];
  const [session] = buildSessionReports(records);
  const [alert] = alerts(session.segments);
  assert.equal(session.alertCount, 1);
  assert.equal(session.events.length, 4);
  assert.equal(alert.detail.occurrence_count, 3);
  assert.equal(alert.detail.peak_rss_mb, 450);
  assert.equal(alert.detail.duration_ms, 20000);
  assert.equal(alert.detail.latest_sample.rss_mb, 420);
  assert.match(alert.label, /窗口增长 12\.0 MB/);
  assert.match(alert.label, /合并 3 条观测/);
});

test('different detector types, resources, or recovered episodes stay distinct', () => {
  const result = alerts(buildSegments([page,
    growth('g1', 10, { episode_id: 'one' }),
    growth('g2', 20, { episode_id: 'two' }),
    growth('p', 30, { type: 'memory_pressure', episode_id: 'two' }),
    growth('r1', 40, { type: 'stream_resource_growth', resource_class: 'Timer', episode_id: 'resources' }),
    growth('r2', 50, { type: 'stream_resource_growth', resource_class: 'StreamController', episode_id: 'resources' }),
  ]));
  assert.equal(result.length, 5);
  assert.equal(result[2].memoryLevel, 'pressure');
  assert.equal(result[3].memoryLevel, 'resource');
});

test('growth after navigation belongs to the observation page, not the exited page', () => {
  const segments = buildSegments([page,
    event('nav', 5, { from: '/a', to: '/b', kind: 'push' }, 'app_transition'),
    growth('g', 10, { route: '/b', observation_scope: 'process' }),
    growth('floor', 15, { route: '/b', type: 'heap_retained_growth',
      observation_scope: 'isolate', gc_verified: true }),
  ]);
  const owner = segments.find(s => s.events.some(e => e.id === 'g'));
  const floorOwner = segments.find(s => s.events.some(e => e.id === 'floor'));
  assert.equal(owner.route, '/b');
  assert.equal(floorOwner.route, '/b');
  assert.match(alerts([floorOwner]).find(e => e.id === 'floor').label, /未确认泄漏/);
});

test('WeakRef transition evidence remains attached to the exited page', () => {
  const segments = buildSegments([page,
    event('nav', 5, { from: '/a', to: '/b', kind: 'pop' }, 'app_transition'),
    event('weak', 10, { route: '/a', aliveCount: 1 }, 'perf_transition_leak'),
  ]);
  const owner = segments.find(s => s.events.some(e => e.id === 'weak'));
  assert.equal(owner.route, '/a');
});

test('duplicate event IDs and distant legacy observations are handled separately', () => {
  const duplicate = growth('g', 10);
  const result = alerts(buildSegments([page, duplicate, duplicate, growth('later', 1000)]));
  assert.equal(result.length, 2);
  assert.equal(result[0].detail.occurrence_count, 1);
});

test('GC frequency and resource counts use their own units', () => {
  const result = alerts(buildSegments([page,
    event('gc', 10, { type: 'gc_pressure', gc_count: 35, rss_mb: 500 }),
    event('resources', 15, { type: 'stream_resource_growth', resource_class: 'Timer', instance_delta: 6 }),
  ]));
  assert.match(result[0].label, /35 次 \/ 10 秒/);
  assert.match(result[1].label, /新增 6 个/);
  assert.doesNotMatch(result[1].label, /MB/);
});
