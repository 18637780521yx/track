import { DownOutlined, RightOutlined } from '@ant-design/icons';
import { Button, DatePicker, Empty, Popconfirm, Spin, Table, Tag, Typography, message } from 'antd';
import type { ColumnsType } from 'antd/es/table';
import { useEffect, useMemo, useState, type Key } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { api, DateRange, defaultRange, normalizeRange } from '../api/client';
import {
  SessionReport,
  TimelineEvent,
  TimelineSegment,
  buildSessionReports,
  fetchReportEvents,
} from '../report/buildSessionTimeline';

const { RangePicker } = DatePicker;
const { Text } = Typography;

type FilterKey = 'all' | 'lifecycle' | 'page' | 'transition';

function fmtDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  const m = Math.floor(ms / 60_000);
  const s = Math.round((ms % 60_000) / 1000);
  return `${m}m ${s}s`;
}

function fmtTime(iso: string): string {
  try {
    return new Date(iso).toLocaleString();
  } catch {
    return iso;
  }
}

function shortId(id: string, head = 8, tail = 4): string {
  if (!id || id.length <= head + tail + 1) return id || '—';
  return `${id.slice(0, head)}…${id.slice(-tail)}`;
}

function prettyBody(raw: unknown): string {
  if (raw == null) return '';
  const s = typeof raw === 'string' ? raw : JSON.stringify(raw);
  const t = s.trim();
  if (!t) return '';
  if (t.startsWith('{') || t.startsWith('[')) {
    try {
      return JSON.stringify(JSON.parse(t), null, 2);
    } catch {
      /* keep raw */
    }
  }
  return s;
}

function prettyHeaders(h: unknown): string {
  if (h == null) return '';
  if (typeof h === 'string') return h;
  try {
    return JSON.stringify(h, null, 2);
  } catch {
    return String(h);
  }
}

function NetworkDetail({ detail }: { detail?: Record<string, unknown> }) {
  if (!detail) return null;
  const status = detail.statusCode ?? detail.status_code;
  const bytes = detail.responseBytes ?? detail.response_bytes;
  const url = String(detail.finalUrl ?? detail.url ?? '');
  const reqH = prettyHeaders(detail.requestHeaders ?? detail.request_headers);
  const resH = prettyHeaders(detail.responseHeaders ?? detail.response_headers);
  const reqB = prettyBody(detail.requestBody ?? detail.request_body);
  const resB = prettyBody(detail.responseBody ?? detail.response_body);
  const hasBody = !!(reqH || resH || reqB || resB || url);
  if (!hasBody && status == null) return null;

  const statusNum = typeof status === 'number' ? status : Number(status);
  const statusCls =
    Number.isFinite(statusNum) && statusNum >= 400
      ? 'bad'
      : Number.isFinite(statusNum) && statusNum >= 300
        ? 'warn'
        : 'ok';

  return (
    <details className="rpt-net-card">
      <summary>
        查看请求详情
        {status != null && (
          <span className={`rpt-net-status ${statusCls}`}>HTTP {String(status)}</span>
        )}
        {bytes != null && <span className="rpt-net-bytes">{String(bytes)} B</span>}
        {url ? <span className="rpt-net-url">{url}</span> : null}
      </summary>
      <div className="rpt-net-grid">
        <div>
          <h4>Request Headers</h4>
          <pre>{reqH || '(none)'}</pre>
          <h4>Request Body</h4>
          <pre>{reqB || '(empty)'}</pre>
        </div>
        <div>
          <h4>Response Headers</h4>
          <pre>{resH || '(none)'}</pre>
          <h4>Response Body</h4>
          <pre>{resB || '(empty)'}</pre>
        </div>
      </div>
    </details>
  );
}

function EventRow({ ev }: { ev: TimelineEvent }) {
  if (ev.type === 'alert') {
    return (
      <div className="rpt-ar-alert">
        <span className="rpt-ar-alert-icon">⚠</span>
        <span>{ev.label}</span>
        {ev.ms != null && <span className="rpt-ar-ms">{Math.round(ev.ms)} ms</span>}
      </div>
    );
  }

  const note =
    ev.type === 'cold_start' && ev.detail?.note != null
      ? String(ev.detail.note)
      : '';
  const pct =
    ev.type === 'cold_start' && typeof ev.detail?.pctOfTtff === 'number'
      ? (ev.detail.pctOfTtff as number)
      : undefined;
  const isTotal = ev.detail?.isTotal === true;
  const highlight = ev.detail?.highlight === true;

  return (
    <div
      className={`rpt-ar-wrap${ev.type === 'network' ? ' is-net' : ''}`}
    >
      <div
        className={`rpt-ar rpt-ar-${ev.type}${ev.ok ? '' : ' fail'}${
          isTotal ? ' total' : ''
        }${highlight ? ' highlight' : ''}`}
      >
        <span className="rpt-ar-dot" />
        <span className="rpt-ar-label">
          {ev.label}
          {note ? <span className="rpt-ar-note"> · {note}</span> : null}
        </span>
        {pct != null && <span className="rpt-ar-pct">{pct}%</span>}
        {ev.ms != null && <span className="rpt-ar-ms">{Math.round(ev.ms)} ms</span>}
        {ev.source && <span className={`rpt-badge src-${ev.source}`}>{ev.source}</span>}
      </div>
      {ev.type === 'network' && <NetworkDetail detail={ev.detail} />}
    </div>
  );
}

function SegmentCard({ seg, index }: { seg: TimelineSegment; index: number }) {
  return (
    <li className={`rpt-seg-item ${seg.module}`} data-module={seg.module}>
      <div className="rpt-seg-time" title={fmtTime(seg.at)}>
        {fmtTime(seg.at)}
      </div>
      <div className="rpt-seg">
        <div className="rpt-seg-head">
          <div>
            <div className="rpt-seg-title">
              <span className="rpt-seg-idx">{index + 1}</span>
              <span className="rpt-seg-sep">·</span>
              <span>{seg.title}</span>
              <span className={`rpt-badge mod-${seg.module}`}>
                {seg.module === 'lifecycle'
                  ? '生命周期'
                  : seg.module === 'page'
                    ? '页面'
                    : '转场'}
              </span>
            </div>
            {seg.module === 'page' && (seg.actionCount > 0 || seg.networkCount > 0 || seg.alertCount > 0) && (
              <div className="rpt-seg-meta">
                {seg.actionCount} 操作
                {seg.networkCount > 0 ? ` · ${seg.networkCount} 请求` : ''}
                {seg.alertCount > 0 ? (
                  <span className="rpt-meta-alert"> · {seg.alertCount} 告警</span>
                ) : null}
              </div>
            )}
            {seg.module === 'lifecycle' && (seg.ttffMs != null || seg.ttiMs != null) && (
              <div className="rpt-seg-meta">
                {seg.ttffMs != null && <span>TTFF {Math.round(seg.ttffMs)} ms</span>}
                {seg.ttffMs != null && seg.ttiMs != null && ' · '}
                {seg.ttiMs != null && <span>TTI {Math.round(seg.ttiMs)} ms</span>}
              </div>
            )}
            {seg.module === 'lifecycle' && seg.route && (
              <div className="rpt-seg-meta">route: {seg.route}</div>
            )}
          </div>
        </div>

        {seg.module === 'page' && seg.events.length === 0 && !seg.exitTo && (
          <div className="rpt-empty-ops">无操作</div>
        )}

        {seg.events.length > 0 && (
          <div className="rpt-actions">
            {seg.events.map((ev) => (
              <EventRow key={ev.id} ev={ev} />
            ))}
          </div>
        )}

        {seg.module === 'page' && seg.exitTo && (
          <div className="rpt-tr-row rpt-tr-exit">
            <span className="rpt-badge mod-transition">转场</span>
            {seg.modalPhase && (
              <span className={`rpt-kind-chip phase-${seg.modalPhase}`}>
                {seg.modalPhase === 'open' ? '出现' : '消失'}
              </span>
            )}
            {seg.exitKind && (
              <span className="rpt-kind-chip">
                kind <b>{seg.exitKind}</b>
              </span>
            )}
            <span className="rpt-kind-chip">
              to <b>{seg.exitTo}</b>
            </span>
            {seg.leakHint && <div className="rpt-tr-warn">{seg.leakHint}</div>}
          </div>
        )}
      </div>
    </li>
  );
}

function SessionDetail({ session, onBack }: { session: SessionReport; onBack: () => void }) {
  const [filter, setFilter] = useState<FilterKey>('all');

  const visible = useMemo(() => {
    if (filter === 'all') return session.segments.filter((s) => s.module !== 'transition');
    if (filter === 'transition') {
      return session.segments.filter((s) => s.module === 'page' && !!s.exitTo);
    }
    return session.segments.filter((s) => s.module === filter);
  }, [session.segments, filter]);

  return (
    <div className="rpt-panel">
      <div className="rpt-detail-bar">
        <Button type="link" onClick={onBack} style={{ paddingLeft: 0 }}>
          ← 返回列表
        </Button>
      </div>

      <div className="rpt-summary">
        <div className="rpt-summary-title">
          <span className="rpt-doc-icon">☰</span>
          <div>
            <h2>{session.title}</h2>
            <p className="rpt-sub">
              用户 {session.distinctId || '未登录'} · anon {shortId(session.anonymousId, 10, 6)}
              <br />
              设备 {session.deviceLabel}
              {session.deviceUdid ? ` · udid ${shortId(session.deviceUdid, 10, 6)}` : ''}
              {session.deviceOs ? ` · ${session.deviceOs}` : ''}
              {session.appVersion ? ` · v${session.appVersion}` : ''}
              <br />
              session {session.sessionId}
              <br />
              {fmtTime(session.startAt)} → {fmtTime(session.endAt)} ·{' '}
              {fmtDuration(session.durationMs)}
            </p>
          </div>
        </div>
        <div className="rpt-pills">
          <span className="rpt-pill">{session.stepCount} steps</span>
          <span className={`rpt-pill${session.alertCount ? ' bad' : ''}`}>
            {session.alertCount} alerts
          </span>
          {session.avgFps != null && (
            <span className="rpt-pill muted">avg FPS {session.avgFps.toFixed(1)}</span>
          )}
          {session.rssPeakMb != null && (
            <span className="rpt-pill muted">RSS {session.rssPeakMb.toFixed(1)} MB</span>
          )}
          <span className="rpt-pill muted">{session.actionCount} 操作</span>
          <span className="rpt-pill muted">{session.networkCount} 网络</span>
        </div>
      </div>

      <h3 className="rpt-section-title">全会话时间线</h3>
      <p className="rpt-hint">
        页面级操作路径：生命周期 / 页面；离开页末尾附带转场（kind / to）。性能问题内联在对应段内。
      </p>
      <div className="rpt-filters">
        {(
          [
            ['all', '全部'],
            ['lifecycle', '生命周期'],
            ['page', '页面'],
            ['transition', '转场'],
          ] as const
        ).map(([key, label]) => (
          <button
            key={key}
            type="button"
            className={`rpt-chip${filter === key ? ' active' : ''}`}
            onClick={() => setFilter(key)}
          >
            {label}
          </button>
        ))}
      </div>

      {visible.length === 0 ? (
        <Empty description="该筛选下无模块段" />
      ) : (
        <ol className="rpt-seg-timeline">
          {visible.map((seg, i) => (
            <SegmentCard key={seg.id} seg={seg} index={i} />
          ))}
        </ol>
      )}
    </div>
  );
}

function useReportSessions(range: DateRange) {
  const [loading, setLoading] = useState(false);
  const [sessions, setSessions] = useState<SessionReport[]>([]);
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    setLoading(true);
    fetchReportEvents(api.listEvents, range)
      .then((items) => setSessions(buildSessionReports(items)))
      .catch((e) => message.error(e.message))
      .finally(() => setLoading(false));
  }, [range, reloadKey]);

  return {
    loading,
    sessions,
    reload: () => setReloadKey((k) => k + 1),
  };
}

interface UserReportGroup {
  key: string;
  distinctId?: string | null;
  anonymousId: string;
  deviceLabel: string;
  deviceUdid: string;
  deviceOs: string;
  appName: string;
  appVersion: string;
  sessions: SessionReport[];
  latestStartAt: string;
  totalDurationMs: number;
  sessionCount: number;
  alertCount: number;
  stepCount: number;
}

function userGroupKey(s: SessionReport): string {
  return s.distinctId || s.anonymousId || s.deviceUdid || s.sessionId;
}

function groupSessionsByUser(sessions: SessionReport[]): UserReportGroup[] {
  const map = new Map<string, SessionReport[]>();
  for (const s of sessions) {
    const key = userGroupKey(s);
    const list = map.get(key);
    if (list) list.push(s);
    else map.set(key, [s]);
  }
  const groups: UserReportGroup[] = [];
  for (const [key, list] of map) {
    const sorted = [...list].sort(
      (a, b) => new Date(b.startAt).getTime() - new Date(a.startAt).getTime(),
    );
    const head = sorted[0];
    groups.push({
      key,
      distinctId: head.distinctId,
      anonymousId: head.anonymousId,
      deviceLabel: head.deviceLabel,
      deviceUdid: head.deviceUdid,
      deviceOs: head.deviceOs,
      appName: head.appName,
      appVersion: head.appVersion,
      sessions: sorted,
      latestStartAt: head.startAt,
      totalDurationMs: sorted.reduce((n, s) => n + s.durationMs, 0),
      sessionCount: sorted.length,
      alertCount: sorted.reduce((n, s) => n + s.alertCount, 0),
      stepCount: sorted.reduce((n, s) => n + s.stepCount, 0),
    });
  }
  return groups.sort(
    (a, b) => new Date(b.latestStartAt).getTime() - new Date(a.latestStartAt).getTime(),
  );
}

export function PerfReportPage() {
  const [range, setRange] = useState<DateRange>(defaultRange());
  const { loading, sessions, reload } = useReportSessions(range);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [expandedKeys, setExpandedKeys] = useState<readonly Key[]>([]);
  const navigate = useNavigate();

  const users = useMemo(() => groupSessionsByUser(sessions), [sessions]);

  useEffect(() => {
    setExpandedKeys(users.map((u) => u.key));
  }, [users]);

  const onDelete = async (sessionId: string) => {
    setDeletingId(sessionId);
    try {
      const res = await api.deleteSession(sessionId);
      const d = res.deleted ?? {};
      message.success(
        `已删除（events ${d.events ?? 0} / logs ${d.app_logs ?? 0} / stab ${d.stability_events ?? 0}）`,
      );
      reload();
    } catch (e) {
      message.error(e instanceof Error ? e.message : String(e));
    } finally {
      setDeletingId(null);
    }
  };

  const sessionColumns: ColumnsType<SessionReport> = [
    {
      title: '开始时间',
      dataIndex: 'startAt',
      width: 180,
      render: (v: string) => fmtTime(v),
    },
    {
      title: '时长',
      dataIndex: 'durationMs',
      width: 88,
      render: (ms: number) => fmtDuration(ms),
    },
    {
      title: '段 / 告警',
      key: 'stats',
      width: 100,
      render: (_: unknown, row) => (
        <span>
          {row.stepCount}
          {row.alertCount > 0 ? (
            <>
              {' / '}
              <span style={{ color: '#b42318', fontWeight: 600 }}>{row.alertCount}</span>
            </>
          ) : (
            ' / 0'
          )}
        </span>
      ),
    },
    {
      title: 'session',
      dataIndex: 'sessionId',
      ellipsis: true,
      render: (id: string) => (
        <Text code style={{ fontSize: 11 }}>
          {shortId(id, 10, 6)}
        </Text>
      ),
    },
    {
      title: '操作',
      key: 'actions',
      width: 88,
      render: (_: unknown, row) => (
        <Popconfirm
          title="删除该会话报告？"
          description="将删除该 session 下埋点 / 日志 / 稳定性事件"
          okText="删除"
          cancelText="取消"
          okButtonProps={{ danger: true }}
          onConfirm={(e) => {
            e?.stopPropagation();
            return onDelete(row.sessionId);
          }}
          onCancel={(e) => e?.stopPropagation()}
        >
          <Button
            type="link"
            danger
            size="small"
            loading={deletingId === row.sessionId}
            onClick={(e) => e.stopPropagation()}
          >
            删除
          </Button>
        </Popconfirm>
      ),
    },
  ];

  const columns: ColumnsType<UserReportGroup> = [
    {
      title: '用户标识',
      key: 'user',
      render: (_: unknown, row) => (
        <div>
          <div style={{ fontWeight: 600 }}>
            {row.distinctId ? (
              <>
                <Tag color="blue" style={{ marginRight: 6 }}>
                  登录
                </Tag>
                {row.distinctId}
              </>
            ) : (
              <>
                <Tag style={{ marginRight: 6 }}>匿名</Tag>
                <Text code style={{ fontSize: 12 }}>
                  {shortId(row.anonymousId, 10, 6)}
                </Text>
              </>
            )}
          </div>
          {row.distinctId && row.anonymousId && (
            <div style={{ fontSize: 12, color: '#5b6b62', marginTop: 2 }}>
              anon {shortId(row.anonymousId, 8, 4)}
            </div>
          )}
        </div>
      ),
    },
    {
      title: '设备',
      key: 'device',
      render: (_: unknown, row) => (
        <div>
          <div>{row.deviceLabel}</div>
          <div style={{ fontSize: 12, color: '#5b6b62' }}>
            {row.deviceUdid ? (
              <Text code style={{ fontSize: 11 }}>
                {shortId(row.deviceUdid, 10, 6)}
              </Text>
            ) : (
              '—'
            )}
            {row.deviceOs ? ` · ${row.deviceOs}` : ''}
          </div>
        </div>
      ),
    },
    {
      title: '会话数',
      dataIndex: 'sessionCount',
      width: 80,
      render: (n: number) => <Tag color={n > 1 ? 'blue' : undefined}>{n} 次</Tag>,
    },
    {
      title: '最近开始',
      dataIndex: 'latestStartAt',
      width: 180,
      render: (v: string) => fmtTime(v),
    },
    {
      title: '合计时长',
      dataIndex: 'totalDurationMs',
      width: 100,
      render: (ms: number) => fmtDuration(ms),
    },
    {
      title: '段 / 告警',
      key: 'stats',
      width: 100,
      render: (_: unknown, row) => (
        <span>
          {row.stepCount}
          {row.alertCount > 0 ? (
            <>
              {' / '}
              <span style={{ color: '#b42318', fontWeight: 600 }}>{row.alertCount}</span>
            </>
          ) : (
            ' / 0'
          )}
        </span>
      ),
    },
    {
      title: 'App',
      key: 'app',
      width: 120,
      ellipsis: true,
      render: (_: unknown, row) =>
        [row.appName, row.appVersion ? `v${row.appVersion}` : ''].filter(Boolean).join(' ') || '—',
    },
  ];

  return (
    <Spin spinning={loading}>
      <div className="page-header">
        <h1 className="page-title">会话报告</h1>
        <RangePicker
          value={range}
          onChange={(v) => v && setRange(normalizeRange(v as DateRange))}
          allowClear={false}
        />
      </div>
      <p className="rpt-hint" style={{ marginTop: -8, marginBottom: 12 }}>
        按用户聚合；同一匿名/登录用户的多次冷启会并成一行，展开查看各 session。
      </p>

      <Table
        rowKey="key"
        size="middle"
        pagination={{ pageSize: 20, showSizeChanger: false }}
        dataSource={users}
        columns={columns}
        expandable={{
          expandIconColumnIndex: columns.length,
          expandedRowKeys: expandedKeys,
          onExpandedRowsChange: setExpandedKeys,
          expandIcon: ({ expanded, onExpand, record }) => (
            <button
              type="button"
              className="rpt-expand-btn"
              aria-label={expanded ? '收起行' : '展开行'}
              aria-expanded={expanded}
              onClick={(e) => onExpand(record, e)}
            >
              {expanded ? <DownOutlined /> : <RightOutlined />}
            </button>
          ),
          expandedRowRender: (user) => (
            <Table
              rowKey="sessionId"
              size="small"
              pagination={false}
              dataSource={user.sessions}
              columns={sessionColumns}
              onRow={(row) => ({
                onClick: () => navigate(`/reports/${encodeURIComponent(row.sessionId)}`),
                style: { cursor: 'pointer' },
              })}
            />
          ),
          rowExpandable: (user) => user.sessionCount > 0,
        }}
        locale={{ emptyText: <Empty description="暂无报告埋点" /> }}
      />
    </Spin>
  );
}

export function PerfReportDetailPage() {
  const { sessionId: rawId = '' } = useParams();
  const sessionId = decodeURIComponent(rawId);
  const navigate = useNavigate();
  const [range, setRange] = useState<DateRange>(defaultRange(14));
  const { loading, sessions } = useReportSessions(range);

  const session = useMemo(
    () => sessions.find((s) => s.sessionId === sessionId) ?? null,
    [sessions, sessionId],
  );

  return (
    <Spin spinning={loading}>
      <div className="page-header">
        <h1 className="page-title">会话详情</h1>
        <RangePicker
          value={range}
          onChange={(v) => v && setRange(normalizeRange(v as DateRange))}
          allowClear={false}
        />
      </div>

      {!loading && !session ? (
        <div className="rpt-panel">
          <Empty
            description={
              <span>
                未找到会话 <Text code>{shortId(sessionId, 12, 6)}</Text>
                ，可调整日期或
                <Link to="/reports"> 返回列表</Link>
              </span>
            }
          />
        </div>
      ) : session ? (
        <SessionDetail session={session} onBack={() => navigate('/reports')} />
      ) : null}
    </Spin>
  );
}
