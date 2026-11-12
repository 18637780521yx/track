import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import ts from 'typescript';

const source = await readFile(new URL('../src/report/buildSessionTimeline.ts', import.meta.url), 'utf8');
const { outputText } = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ESNext },
});
const { buildSessionReports } = await import(`data:text/javascript;base64,${Buffer.from(outputText).toString('base64')}`);
function event(id, seconds, name, properties) {
  const at = new Date(Date.UTC(2026, 10, 12) + seconds * 1000).toISOString();
  return { event_id: id, name, properties, session_id: 'frames', anonymous_id: 'test',
    event_time: at, received_at: at };
}
const page = event('page', 0, 'app_page', { route: '/a', frame_route_epoch: 1 });
const window = (id, seconds, extra = {}) => event(id, seconds, 'app_jank', {
  type: 'frame_window', route: '/a', route_epoch: 1, detector_version: 2,
  frozen_reported_separately: true, ...extra,
});

test('pipeline latency stays visible without increasing the jank alert count', () => {
  const [session] = buildSessionReports([page, window('latency', 10,
    { severity: 'latency', slow_frames: 0, high_latency_frames: 5, jank_rate: 0 })]);
  assert.equal(session.alertCount, 0);
  const observation = session.segments.flatMap(s => s.events).find(e => e.id === 'latency');
  assert.match(observation.label, /非处理卡顿/);
  assert.equal(observation.informational, true);
});

test('frozen frame and its summary count as one alert', () => {
  const [session] = buildSessionReports([page,
    event('frozen', 5, 'app_jank', { type: 'frozen_frame', route: '/a', total_ms: 800, severity: 'frozen' }),
    window('summary', 10, { severity: 'frozen', frozen_frames: 1, jank_detected: false, sustained_jank: false }),
  ]);
  assert.equal(session.alertCount, 1);
  assert.equal(session.segments.flatMap(s => s.events).filter(e => e.type === 'alert').length, 2);
});

test('late-start and severe-pattern evidence is visible in the summary', () => {
  const [session] = buildSessionReports([page, window('pattern', 10, {
    severity: 'severe', sustained_jank: true, jank_rate: .03, late_start_frames: 3,
  })]);
  assert.equal(session.alertCount, 1);
  const label = session.segments.flatMap(s => s.events).find(e => e.id === 'pattern').label;
  assert.match(label, /持续严重卡顿/);
  assert.match(label, /开始处理晚×3/);
  assert.match(label, /慢帧 3\.0%/);
});

test('late delivery after returning to the same route uses the original visit epoch', () => {
  const [session] = buildSessionReports([page,
    event('ab', 2, 'app_transition', { from: '/a', to: '/b', kind: 'push', frame_route_epoch: 2 }),
    event('ba', 4, 'app_transition', { from: '/b', to: '/a', kind: 'pop', frame_route_epoch: 3 }),
    window('old', 10, { jank_detected: true, severity: 'slow', jank_rate: .5 }),
  ]);
  const owner = session.segments.find(s => s.events.some(e => e.id === 'old'));
  assert.equal(owner.route, '/a');
  assert.equal(owner.frameRouteEpoch, 1);
});
