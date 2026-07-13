import { AutoComplete, App, Button, Card, Col, DatePicker, Row, Spin, Table } from 'antd';
import ReactECharts from 'echarts-for-react';
import { useEffect, useState } from 'react';
import { api, DateRange, defaultRange } from '../api/client';

const { RangePicker } = DatePicker;

export function EventAnalysisPage() {
  const { message } = App.useApp();
  const [range, setRange] = useState<DateRange>(defaultRange());
  const [eventNames, setEventNames] = useState<string[]>([]);
  const [inputEvent, setInputEvent] = useState('');
  const [selectedEvent, setSelectedEvent] = useState('');
  const [loading, setLoading] = useState(false);
  const [trend, setTrend] = useState<{ bucket: string; count: number; users: number }[]>([]);
  const [records, setRecords] = useState<Awaited<ReturnType<typeof api.listEvents>> | null>(null);

  useEffect(() => {
    api
      .eventNames()
      .then((res) => {
        const names = (res.items ?? []).map((i) => i.name);
        setEventNames(names);
        if (names.length > 0) {
          setInputEvent(names[0]);
          setSelectedEvent(names[0]);
        }
      })
      .catch((e) => message.error(e.message));
  }, [message]);

  const loadSuggestions = async (keyword: string) => {
    try {
      const res = await api.eventNames(keyword);
      setEventNames((res.items ?? []).map((i) => i.name));
    } catch (e) {
      message.error((e as Error).message);
    }
  };

  const runQuery = (eventName: string) => {
    const name = eventName.trim();
    if (!name) {
      message.warning('请输入事件名');
      return;
    }
    setInputEvent(name);
    setSelectedEvent(name);
  };

  useEffect(() => {
    if (!selectedEvent) return;
    setLoading(true);
    Promise.all([
      api.eventTrend(range, selectedEvent),
      api.listEvents(range, selectedEvent, 30),
    ])
      .then(([trendRes, listRes]) => {
        setTrend(trendRes.items ?? []);
        setRecords(listRes);
      })
      .catch((e) => {
        message.error(e.message);
        setTrend([]);
        setRecords(null);
      })
      .finally(() => setLoading(false));
  }, [range, selectedEvent, message]);

  const chartOption = {
    tooltip: { trigger: 'axis' },
    legend: { data: ['触发次数', '触发用户'] },
    grid: { left: 40, right: 20, top: 40, bottom: 30 },
    xAxis: { type: 'category', data: trend.map((d) => d.bucket) },
    yAxis: { type: 'value' },
    series: [
      { name: '触发次数', type: 'bar', data: trend.map((d) => d.count) },
      { name: '触发用户', type: 'line', smooth: true, data: trend.map((d) => d.users) },
    ],
  };

  return (
    <Spin spinning={loading}>
      <div className="page-header">
        <h1 className="page-title">事件分析</h1>
        <div style={{ display: 'flex', gap: 12 }}>
          <AutoComplete
            style={{ width: 280 }}
            value={inputEvent}
            options={eventNames.map((n) => ({ value: n }))}
            onChange={(v) => {
              setInputEvent(v);
              if (v) loadSuggestions(v);
            }}
            onSelect={runQuery}
            placeholder="输入或选择事件名"
            filterOption={false}
          />
          <Button type="primary" onClick={() => runQuery(inputEvent)}>
            查询
          </Button>
          <RangePicker
            value={range}
            onChange={(v) => v && setRange(v as DateRange)}
            allowClear={false}
          />
        </div>
      </div>

      <Row gutter={16}>
        <Col span={24}>
          <Card title={selectedEvent ? `「${selectedEvent}」趋势` : '事件趋势'}>
            <ReactECharts option={chartOption} style={{ height: 360 }} />
          </Card>
        </Col>
      </Row>

      <Card title="事件明细" style={{ marginTop: 16 }}>
        <Table
          rowKey="event_id"
          size="small"
          dataSource={records?.items ?? []}
          pagination={{ total: records?.total, pageSize: 30, showSizeChanger: false }}
          columns={[
            { title: '事件名', dataIndex: 'name', width: 140 },
            { title: '用户 ID', dataIndex: 'distinct_id', width: 160, render: (v, r) => v || r.anonymous_id },
            { title: '时间', dataIndex: 'event_time', width: 180 },
            {
              title: '属性',
              dataIndex: 'properties',
              render: (v: Record<string, unknown>) => JSON.stringify(v),
              ellipsis: true,
            },
          ]}
        />
      </Card>
    </Spin>
  );
}
