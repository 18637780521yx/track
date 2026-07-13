import {
  Button,
  Card,
  Col,
  DatePicker,
  Descriptions,
  Row,
  Spin,
  Tag,
  Timeline,
  Typography,
  message,
} from 'antd';
import { useEffect, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { api, DateRange, EventRecord, UserRecord, defaultRange } from '../api/client';

const { RangePicker } = DatePicker;
const { Text, Paragraph } = Typography;

function formatProps(props: Record<string, unknown>) {
  const entries = Object.entries(props);
  if (entries.length === 0) return '无';
  return entries.map(([k, v]) => `${k}: ${JSON.stringify(v)}`).join(' · ');
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

  useEffect(() => {
    if (!userId) return;
    setLoading(true);
    Promise.all([api.getUser(userId), api.listUserEvents(userId, range)])
      .then(([userRes, eventsRes]) => {
        setUser(userRes);
        setEvents(eventsRes.items);
        setTotal(eventsRes.total);
      })
      .catch((e) => message.error(e.message))
      .finally(() => setLoading(false));
  }, [userId, range]);

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
          onChange={(v) => v && setRange(v as DateRange)}
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

      <Row gutter={16}>
        <Col span={24}>
          <Card title={`行为时间线（${total} 条）`}>
            {events.length === 0 ? (
              <Text type="secondary">该时间范围内暂无埋点数据</Text>
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
                      <Paragraph className="timeline-props" type="secondary">
                        属性：{formatProps(event.properties)}
                      </Paragraph>
                      <Text type="secondary" style={{ fontSize: 12 }}>
                        session: {event.session_id.slice(0, 8)}…
                      </Text>
                    </div>
                  ),
                }))}
              />
            )}
          </Card>
        </Col>
      </Row>
    </Spin>
  );
}
