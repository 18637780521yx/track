import { Card, Col, DatePicker, Row, Spin, Statistic, Table, message } from 'antd';
import ReactECharts from 'echarts-for-react';
import { useEffect, useState } from 'react';
import { api, DateRange, defaultRange } from '../api/client';

const { RangePicker } = DatePicker;

export function OverviewPage() {
  const [range, setRange] = useState<DateRange>(defaultRange());
  const [loading, setLoading] = useState(false);
  const [data, setData] = useState<Awaited<ReturnType<typeof api.overview>> | null>(null);

  useEffect(() => {
    setLoading(true);
    api
      .overview(range)
      .then(setData)
      .catch((e) => message.error(e.message))
      .finally(() => setLoading(false));
  }, [range]);

  const trendOption = {
    tooltip: { trigger: 'axis' },
    legend: { data: ['日活', '新增', '安装'] },
    grid: { left: 40, right: 20, top: 40, bottom: 30 },
    xAxis: { type: 'category', data: data?.trend.map((d) => d.date) ?? [] },
    yAxis: { type: 'value' },
    series: [
      {
        name: '日活',
        type: 'line',
        smooth: true,
        data: data?.trend.map((d) => d.users) ?? [],
      },
      {
        name: '新增',
        type: 'line',
        smooth: true,
        data: data?.trend.map((d) => d.new_users ?? 0) ?? [],
      },
      {
        name: '安装',
        type: 'bar',
        data: data?.trend.map((d) => d.installs ?? 0) ?? [],
        itemStyle: { opacity: 0.7 },
      },
    ],
  };

  return (
    <Spin spinning={loading}>
      <div className="page-header">
        <h1 className="page-title">数据概览</h1>
        <RangePicker
          value={range}
          onChange={(v) => v && setRange(v as DateRange)}
          allowClear={false}
        />
      </div>

      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        <Col xs={12} sm={8} lg={4}>
          <Card className="stat-card">
            <Statistic title="日活 (DAU)" value={data?.dau ?? 0} />
          </Card>
        </Col>
        <Col xs={12} sm={8} lg={4}>
          <Card className="stat-card">
            <Statistic title="新增用户" value={data?.new_users ?? 0} />
          </Card>
        </Col>
        <Col xs={12} sm={8} lg={4}>
          <Card className="stat-card">
            <Statistic title="安装 (首开)" value={data?.installs ?? 0} />
          </Card>
        </Col>
        <Col xs={12} sm={8} lg={4}>
          <Card className="stat-card">
            <Statistic title="付费用户" value={data?.paying_users ?? 0} />
          </Card>
        </Col>
        <Col xs={12} sm={8} lg={4}>
          <Card className="stat-card">
            <Statistic title="收入" value={data?.revenue ?? 0} precision={2} prefix="¥" />
          </Card>
        </Col>
        <Col xs={12} sm={8} lg={4}>
          <Card className="stat-card">
            <Statistic title="活跃订阅" value={data?.active_subscriptions ?? 0} />
          </Card>
        </Col>
      </Row>

      <Row gutter={16}>
        <Col span={16}>
          <Card title="用户趋势">
            <ReactECharts option={trendOption} style={{ height: 320 }} />
          </Card>
        </Col>
        <Col span={8}>
          <Card title="Top 事件">
            <Table
              size="small"
              pagination={false}
              rowKey="name"
              dataSource={data?.top_events ?? []}
              columns={[
                { title: '事件名', dataIndex: 'name', ellipsis: true },
                { title: '次数', dataIndex: 'count', width: 80 },
              ]}
            />
          </Card>
        </Col>
      </Row>
    </Spin>
  );
}
