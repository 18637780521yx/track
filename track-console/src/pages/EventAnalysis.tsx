import { AutoComplete, App, Button, Card, Col, DatePicker, Row, Segmented, Spin, Table } from 'antd';
import ReactECharts from 'echarts-for-react';
import { useEffect, useMemo, useState } from 'react';
import { api, DateRange, defaultRange, normalizeRange } from '../api/client';
import { JsonPanel } from '../components/JsonPanel';
import {
  PropertyFilterBar,
  PropertyFilter,
  activeFilters,
  newFilter,
} from '../components/PropertyFilterBar';

const { RangePicker } = DatePicker;

type EnvValue = '' | 'sandbox' | 'production';

export function EventAnalysisPage() {
  const { message } = App.useApp();
  const [range, setRange] = useState<DateRange>(defaultRange());
  const [eventNames, setEventNames] = useState<string[]>([]);
  const [inputEvent, setInputEvent] = useState('');
  const [selectedEvent, setSelectedEvent] = useState('');
  const [environment, setEnvironment] = useState<EnvValue>('');
  const [filters, setFilters] = useState<PropertyFilter[]>([]);
  const [appliedFilters, setAppliedFilters] = useState<ReturnType<typeof activeFilters>>([]);
  const [valueOptions, setValueOptions] = useState<Record<string, string[]>>({});
  const [loading, setLoading] = useState(false);
  const [trend, setTrend] = useState<{ bucket: string; count: number; users: number }[]>([]);
  const [records, setRecords] = useState<Awaited<ReturnType<typeof api.listEvents>> | null>(null);

  const queryFilters = useMemo(() => {
    const list = appliedFilters.filter(
      (f) => !(f.source === 'common' && f.field === 'environment'),
    );
    if (environment) {
      list.unshift({
        source: 'common',
        field: 'environment',
        op: 'eq',
        value: environment,
      });
    }
    return list;
  }, [appliedFilters, environment]);

  const filterKey = useMemo(() => JSON.stringify(queryFilters), [queryFilters]);

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

  const loadValueOptions = async (filter: PropertyFilter) => {
    const field = filter.field.trim();
    if (!field) return;
    const key = `${filter.source}:${field}`;
    if (valueOptions[key]?.length) return;
    try {
      const res = await api.propertyValues(field, filter.source, selectedEvent);
      setValueOptions((prev) => ({ ...prev, [key]: res.items ?? [] }));
    } catch {
      // ignore
    }
  };

  const runQuery = () => {
    const name = inputEvent.trim();
    if (!name) {
      message.warning('请输入事件名');
      return;
    }
    setSelectedEvent(name);
    setAppliedFilters(activeFilters(filters));
  };

  useEffect(() => {
    if (!selectedEvent) return;
    setLoading(true);
    Promise.all([
      api.eventTrend(range, selectedEvent, 'day', queryFilters),
      api.listEvents(range, selectedEvent, 30, 0, queryFilters),
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
  }, [range, selectedEvent, filterKey, queryFilters, message]);

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
        <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', alignItems: 'center' }}>
          <Segmented
            value={environment}
            onChange={(v) => setEnvironment(v as EnvValue)}
            options={[
              { label: '全部环境', value: '' },
              { label: 'sandbox', value: 'sandbox' },
              { label: 'production', value: 'production' },
            ]}
          />
          <AutoComplete
            style={{ width: 280 }}
            value={inputEvent}
            options={eventNames.map((n) => ({ value: n }))}
            onChange={(v) => {
              setInputEvent(v);
              if (v) loadSuggestions(v);
            }}
            onSelect={(v) => setInputEvent(v)}
            placeholder="输入或选择事件名"
            filterOption={false}
          />
          <RangePicker
            value={range}
            onChange={(v) => v && setRange(normalizeRange(v as DateRange))}
            allowClear={false}
          />
          <Button type="primary" onClick={runQuery}>
            查询
          </Button>
        </div>
      </div>

      <Card size="small" title="筛选条件（AND）" style={{ marginBottom: 16 }}>
        <PropertyFilterBar
          filters={filters}
          onChange={setFilters}
          valueOptions={valueOptions}
          onLoadValues={loadValueOptions}
        />
        {filters.length === 0 && (
          <Button
            type="link"
            style={{ paddingLeft: 0 }}
            onClick={() => setFilters([newFilter({ field: 'app_version' })])}
          >
            + 添加条件（如 app_version = 1.7.1）
          </Button>
        )}
      </Card>

      <Row gutter={16}>
        <Col span={24}>
          <Card title={selectedEvent ? `「${selectedEvent}」趋势` : '事件趋势'}>
            <ReactECharts option={chartOption} style={{ height: 360 }} />
          </Card>
        </Col>
      </Row>

      <Card title={`事件明细（${records?.total ?? 0}）`} style={{ marginTop: 16 }}>
        <Table
          rowKey="event_id"
          size="small"
          dataSource={records?.items ?? []}
          pagination={{ total: records?.total, pageSize: 30, showSizeChanger: false }}
          expandable={{
            expandedRowRender: (record) => (
              <JsonPanel value={record.common_properties ?? {}} label="公共属性 common_properties" />
            ),
            rowExpandable: (record) =>
              !!record.common_properties && Object.keys(record.common_properties).length > 0,
          }}
          columns={[
            { title: '事件名', dataIndex: 'name', width: 140 },
            { title: '用户 ID', dataIndex: 'distinct_id', width: 160, render: (v, r) => v || r.anonymous_id },
            {
              title: '时间',
              dataIndex: 'event_time',
              width: 180,
              render: (v: string) => new Date(v).toLocaleString(),
            },
            {
              title: '环境',
              width: 100,
              render: (_, r) => {
                const v = r.common_properties?.environment;
                return typeof v === 'string' && v ? v : '-';
              },
            },
            {
              title: '版本',
              width: 100,
              render: (_, r) => {
                const v = r.common_properties?.app_version;
                return typeof v === 'string' && v ? v : '-';
              },
            },
            {
              title: '事件属性',
              dataIndex: 'properties',
              render: (v: Record<string, unknown>) => <JsonPanel value={v ?? {}} />,
            },
          ]}
        />
      </Card>
    </Spin>
  );
}
