import {
  Button,
  Card,
  DatePicker,
  Descriptions,
  Pagination,
  Popconfirm,
  Segmented,
  Space,
  Spin,
  Tag,
  Timeline,
  Typography,
  message,
} from 'antd';
import { useEffect, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { api, DateRange, EventRecord, UserRecord, defaultRange, normalizeRange } from '../api/client';
import { JsonPanel } from '../components/JsonPanel';

const { RangePicker } = DatePicker;
const { Text } = Typography;

type ViewMode = 'timeline' | 'terminal';

const PAGE_SIZE = 50;

function levelColor(level: string): string {
  switch ((level || '').toLowerCase()) {
    case 'e':
    case 'error':
      return '#ff6b6b';
    case 'w':
    case 'warn':
    case 'warning':
      return '#ffd43b';
    case 'i':
    case 'info':
      return '#69db7c';
    case 'd':
    case 'debug':
      return '#74c0fc';
    case 'v':
    case 'verbose':
      return '#adb5bd';
    default:
      return '#ced4da';
  }
}

function formatLogLine(event: EventRecord): {
  time: string;
  level: string;
  tag: string;
  message: string;
  plain: string;
} {
  const props = (event.properties ?? {}) as Record<string, unknown>;
  const level = String(props.level ?? '').toLowerCase() || '?';
  const tag = String(props.tag ?? event.name ?? '');
  const message = String(props.message ?? JSON.stringify(props));
  const time = new Date(event.event_time).toLocaleString();
  return {
    time,
    level,
    tag,
    message,
    plain: `${time} ${level.toUpperCase()} [${tag}] ${message}`,
  };
}

async function copyText(text: string) {
  try {
    await navigator.clipboard.writeText(text);
    message.success('已复制到剪贴板');
  } catch {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.left = '-9999px';
    document.body.appendChild(ta);
    ta.select();
    try {
      document.execCommand('copy');
      message.success('已复制到剪贴板');
    } catch (err) {
      message.error(err instanceof Error ? err.message : '复制失败');
    }
    ta.remove();
  }
}

export function UserDetailPage() {
  const { id = '' } = useParams();
  const navigate = useNavigate();
  const userId = decodeURIComponent(id);

  const [range, setRange] = useState<DateRange>(defaultRange());
  const [loading, setLoading] = useState(false);
  const [user, setUser] = useState<UserRecord | null>(null);
  const [events, setEvents] = useState<EventRecord[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [view, setView] = useState<ViewMode>('timeline');
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    setPage(1);
  }, [range, view, userId]);

  useEffect(() => {
    if (!userId) return;
    api.getUser(userId).then(setUser).catch((e) => message.error(e.message));
  }, [userId]);

  useEffect(() => {
    if (!userId) return;
    setLoading(true);
    const offset = (page - 1) * PAGE_SIZE;
    const req =
      view === 'terminal'
        ? api.listUserLogs(userId, range, PAGE_SIZE, offset, { order: 'desc' })
        : api.listUserEvents(userId, range, PAGE_SIZE, offset, { order: 'desc' });
    req
      .then((eventsRes) => {
        setEvents(eventsRes.items ?? []);
        setTotal(eventsRes.total);
      })
      .catch((e) => message.error(e.message))
      .finally(() => setLoading(false));
  }, [userId, range, page, view, reloadKey]);

  const title =
    view === 'terminal'
      ? `终端日志（${total} 条 · 仅保留 2 小时）`
      : `行为时间线（${total} 条）`;

  const copyLogs = () => {
    if (events.length === 0) {
      message.info('暂无日志可复制');
      return;
    }
    const text = events.map((e) => formatLogLine(e).plain).join('\n');
    void copyText(text);
  };

  const clearLogs = async () => {
    try {
      const res = await api.deleteUserLogs(userId);
      message.success(`已删除 ${res.deleted} 条日志`);
      setPage(1);
      setReloadKey((k) => k + 1);
    } catch (e) {
      message.error(e instanceof Error ? e.message : '删除失败');
    }
  };

  return (
    <Spin spinning={loading}>
      <div className="page-header">
        <div>
          <Button type="link" style={{ paddingLeft: 0 }} onClick={() => navigate('/users')}>
            ← 返回用户列表
          </Button>
          <h1 className="page-title">用户详情</h1>
        </div>
        <RangePicker
          value={range}
          onChange={(v) => v && setRange(normalizeRange(v as DateRange))}
          allowClear={false}
        />
      </div>

      {user && (
        <Card style={{ marginBottom: 16 }}>
          <Descriptions column={3} size="small">
            <Descriptions.Item label="用户 ID">{user.user_id}</Descriptions.Item>
            <Descriptions.Item label="登录 ID">{user.distinct_id || '-'}</Descriptions.Item>
            <Descriptions.Item label="匿名 ID">{user.anonymous_id}</Descriptions.Item>
            <Descriptions.Item label="渠道">{user.channel || '-'}</Descriptions.Item>
            <Descriptions.Item label="付费">
              {user.is_paid ? <Tag color="gold">是</Tag> : <Tag>否</Tag>}
            </Descriptions.Item>
            <Descriptions.Item label="累计收入">
              {user.total_revenue > 0 ? `¥${user.total_revenue.toFixed(2)}` : '-'}
            </Descriptions.Item>
            <Descriptions.Item label="首次访问">
              {new Date(user.first_seen_at).toLocaleString()}
            </Descriptions.Item>
            <Descriptions.Item label="最近访问">
              {new Date(user.last_seen_at).toLocaleString()}
            </Descriptions.Item>
          </Descriptions>
        </Card>
      )}

      <Card
        title={title}
        extra={
          <Space>
            {view === 'terminal' && (
              <>
                <Button size="small" onClick={copyLogs} disabled={events.length === 0}>
                  复制
                </Button>
                <Popconfirm
                  title="清空该用户全部终端日志？"
                  okText="删除"
                  cancelText="取消"
                  okButtonProps={{ danger: true }}
                  onConfirm={() => void clearLogs()}
                >
                  <Button size="small" danger disabled={total === 0}>
                    删除
                  </Button>
                </Popconfirm>
              </>
            )}
            <Segmented
              value={view}
              onChange={(v) => setView(v as ViewMode)}
              options={[
                { label: '行为时间线', value: 'timeline' },
                { label: '终端日志', value: 'terminal' },
              ]}
            />
          </Space>
        }
      >
        {events.length === 0 ? (
          <Text type="secondary">
            {view === 'terminal'
              ? '最近 2 小时内暂无终端日志'
              : '该时间范围内暂无埋点数据'}
          </Text>
        ) : view === 'terminal' ? (
          <div className="terminal-log">
            {events.map((event) => {
              const line = formatLogLine(event);
              return (
                <div key={event.event_id} className="terminal-log-line">
                  <span className="terminal-log-time">{line.time}</span>
                  <span className="terminal-log-level" style={{ color: levelColor(line.level) }}>
                    {line.level}
                  </span>
                  <span className="terminal-log-tag">{line.tag}</span>
                  <span className="terminal-log-msg">{line.message}</span>
                </div>
              );
            })}
          </div>
        ) : (
          <Timeline
            className="user-timeline"
            items={events.map((event) => ({
              color: event.name.includes('payment') ? 'gold' : 'blue',
              children: (
                <div className="timeline-item">
                  <div className="timeline-item-head">
                    <Text type="secondary">{new Date(event.event_time).toLocaleString()}</Text>
                    <Tag color="processing">{event.name}</Tag>
                  </div>
                  <div className="timeline-props">
                    <JsonPanel value={event.properties ?? {}} />
                  </div>
                  <Text type="secondary" style={{ fontSize: 12, wordBreak: 'break-all' }}>
                    session: {event.session_id}
                  </Text>
                </div>
              ),
            }))}
          />
        )}

        {total > 0 && (
          <div style={{ marginTop: 16, textAlign: 'right' }}>
            <Pagination
              current={page}
              pageSize={PAGE_SIZE}
              total={total}
              showSizeChanger={false}
              showTotal={(t) => `共 ${t} 条`}
              onChange={setPage}
            />
          </div>
        )}
      </Card>
    </Spin>
  );
}
