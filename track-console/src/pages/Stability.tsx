import {
  App,
  Card,
  Col,
  DatePicker,
  Drawer,
  Row,
  Segmented,
  Spin,
  Statistic,
  Table,
  Typography,
} from 'antd';
import ReactECharts from 'echarts-for-react';
import { useEffect, useState } from 'react';
import {
  api,
  DateRange,
  defaultRange,
  normalizeRange,
  StabilityIssueDetail,
  StabilityIssueSummary,
  StabilityOverview,
} from '../api/client';

const { RangePicker } = DatePicker;

type KindFilter = '' | 'crash' | 'error' | 'anr';

const kindLabel: Record<string, string> = {
  crash: '崩溃',
  error: '非致命',
  anr: 'ANR',
};

export function StabilityPage() {
  const { message } = App.useApp();
  const [range, setRange] = useState<DateRange>(defaultRange());
  const [kind, setKind] = useState<KindFilter>('');
  const [loading, setLoading] = useState(false);
  const [overview, setOverview] = useState<StabilityOverview | null>(null);
  const [issues, setIssues] = useState<StabilityIssueSummary[]>([]);
  const [total, setTotal] = useState(0);
  const [detail, setDetail] = useState<StabilityIssueDetail | null>(null);
  const [drawerOpen, setDrawerOpen] = useState(false);

  useEffect(() => {
    setLoading(true);
    Promise.all([
      api.stabilityOverview(range),
      api.stabilityIssues(range, kind, 50, 0),
    ])
      .then(([ov, list]) => {
        setOverview(ov);
        setIssues(list.items ?? []);
        setTotal(list.total ?? 0);
      })
      .catch((e) => message.error(e.message))
      .finally(() => setLoading(false));
  }, [range, kind, message]);

  const openIssue = async (fp: string) => {
    try {
      const d = await api.stabilityIssue(fp);
      setDetail(d);
      setDrawerOpen(true);
    } catch (e) {
      message.error((e as Error).message);
    }
  };

  const trendOption = {
    tooltip: { trigger: 'axis' },
    legend: { data: ['崩溃', '非致命', 'ANR'] },
    grid: { left: 40, right: 20, top: 40, bottom: 30 },
    xAxis: { type: 'category', data: (overview?.trend ?? []).map((d) => d.date) },
    yAxis: { type: 'value' },
    series: [
      {
        name: '崩溃',
        type: 'line',
        smooth: true,
        data: (overview?.trend ?? []).map((d) => d.crash),
      },
      {
        name: '非致命',
        type: 'line',
        smooth: true,
        data: (overview?.trend ?? []).map((d) => d.error),
      },
      {
        name: 'ANR',
        type: 'bar',
        data: (overview?.trend ?? []).map((d) => d.anr),
        itemStyle: { opacity: 0.7 },
      },
    ],
  };

  return (
    <Spin spinning={loading}>
      <div className="page-header">
        <h1 className="page-title">稳定性</h1>
        <RangePicker
          value={range}
          onChange={(v) => v && setRange(normalizeRange(v as DateRange))}
          allowClear={false}
        />
      </div>

      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        <Col xs={12} sm={8} lg={4}>
          <Card className="stat-card">
            <Statistic title="崩溃" value={overview?.crash ?? 0} />
          </Card>
        </Col>
        <Col xs={12} sm={8} lg={4}>
          <Card className="stat-card">
            <Statistic title="非致命异常" value={overview?.error ?? 0} />
          </Card>
        </Col>
        <Col xs={12} sm={8} lg={4}>
          <Card className="stat-card">
            <Statistic title="ANR" value={overview?.anr ?? 0} />
          </Card>
        </Col>
        <Col xs={12} sm={8} lg={4}>
          <Card className="stat-card">
            <Statistic title="Issue 数" value={overview?.issue_count ?? 0} />
          </Card>
        </Col>
        <Col xs={12} sm={8} lg={4}>
          <Card className="stat-card">
            <Statistic title="影响用户" value={overview?.affected_users ?? 0} />
          </Card>
        </Col>
      </Row>

      <Card style={{ marginBottom: 16 }}>
        <ReactECharts option={trendOption} style={{ height: 280 }} />
      </Card>

      <Card
        title={`Issues（${total}）`}
        extra={
          <Segmented
            value={kind || 'all'}
            onChange={(v) => setKind(v === 'all' ? '' : (v as KindFilter))}
            options={[
              { label: '全部', value: 'all' },
              { label: '崩溃', value: 'crash' },
              { label: '非致命', value: 'error' },
              { label: 'ANR', value: 'anr' },
            ]}
          />
        }
      >
        <Table
          rowKey="fingerprint"
          dataSource={issues}
          pagination={false}
          onRow={(row) => ({
            onClick: () => openIssue(row.fingerprint),
            style: { cursor: 'pointer' },
          })}
          columns={[
            {
              title: '类型',
              dataIndex: 'kind',
              width: 90,
              render: (k: string) => kindLabel[k] ?? k,
            },
            {
              title: '异常',
              dataIndex: 'exception_type',
              ellipsis: true,
            },
            {
              title: '信息',
              dataIndex: 'sample_message',
              ellipsis: true,
            },
            {
              title: '次数',
              dataIndex: 'occurrence_count',
              width: 80,
            },
            {
              title: '用户',
              dataIndex: 'user_count',
              width: 80,
            },
            {
              title: '最近出现',
              dataIndex: 'last_seen_at',
              width: 180,
              render: (v: string) => new Date(v).toLocaleString(),
            },
          ]}
        />
      </Card>

      <Drawer
        title={detail ? `${kindLabel[detail.issue.kind] ?? detail.issue.kind} · ${detail.issue.exception_type}` : '详情'}
        width={720}
        open={drawerOpen}
        onClose={() => setDrawerOpen(false)}
      >
        {detail && (
          <>
            <Typography.Paragraph type="secondary">
              fingerprint: {detail.issue.fingerprint}
            </Typography.Paragraph>
            <Typography.Paragraph>
              {detail.issue.sample_message || '（无 message）'}
            </Typography.Paragraph>
            <Typography.Title level={5}>堆栈</Typography.Title>
            <pre
              style={{
                background: '#f5f5f5',
                padding: 12,
                borderRadius: 6,
                maxHeight: 280,
                overflow: 'auto',
                fontSize: 12,
              }}
            >
              {detail.issue.sample_stack || '（无堆栈）'}
            </pre>
            <Typography.Title level={5} style={{ marginTop: 16 }}>
              最近发生（{detail.total}）
            </Typography.Title>
            <Table
              rowKey="event_id"
              size="small"
              dataSource={detail.events}
              pagination={false}
              columns={[
                {
                  title: '时间',
                  dataIndex: 'event_time',
                  width: 170,
                  render: (v: string) => new Date(v).toLocaleString(),
                },
                { title: '版本', dataIndex: 'app_version', width: 90 },
                { title: '设备', dataIndex: 'device_model', ellipsis: true },
                { title: '用户', dataIndex: 'user_id', ellipsis: true },
              ]}
            />
          </>
        )}
      </Drawer>
    </Spin>
  );
}
