import { Button, Card, Col, DatePicker, Input, InputNumber, Row, Select, Space, Spin, Statistic, message } from 'antd';
import ReactECharts from 'echarts-for-react';
import { useEffect, useState } from 'react';
import { api, DateRange, defaultRange, FunnelStep } from '../api/client';

const { RangePicker } = DatePicker;

const defaultSteps = ['app_first_open', 'page_view', 'btn_click', 'payment_success'];

export function FunnelPage() {
  const [range, setRange] = useState<DateRange>(defaultRange());
  const [eventNames, setEventNames] = useState<string[]>([]);
  const [steps, setSteps] = useState<string[]>(defaultSteps);
  const [windowHours, setWindowHours] = useState(24);
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<FunnelStep[]>([]);

  useEffect(() => {
    api.eventNames()
      .then((res) => {
        const names = res.items.map((i) => i.name);
        setEventNames(names);
        const preferred = ['app_first_open', 'page_view', 'btn_click', 'payment_success'];
        const picked = preferred.filter((n) => names.includes(n));
        if (picked.length >= 2) {
          setSteps(picked);
        }
      })
      .catch((e) => message.error(e.message));
  }, []);

  const run = () => {
    if (steps.filter(Boolean).length < 2) {
      message.warning('请至少配置 2 个漏斗步骤');
      return;
    }
    setLoading(true);
    api
      .funnel(range, steps.filter(Boolean), windowHours)
      .then((res) => setResult(res.steps))
      .catch((e) => message.error(e.message))
      .finally(() => setLoading(false));
  };

  useEffect(() => {
    if (steps.filter(Boolean).length >= 2) {
      run();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [range, steps.join('|')]);

  const chartOption = {
    tooltip: {
      trigger: 'axis',
      formatter: (params: { name: string; value: number; dataIndex: number }[]) => {
        const p = params[0];
        const step = result[p.dataIndex];
        return `${p.name}<br/>人数: ${step?.users ?? 0}<br/>转化率: ${(step?.conversion ?? 0).toFixed(1)}%`;
      },
    },
    grid: { left: 40, right: 20, top: 30, bottom: 60 },
    xAxis: {
      type: 'category',
      data: result.map((s) => s.name),
      axisLabel: { rotate: 30 },
    },
    yAxis: { type: 'value', name: '人数' },
    series: [
      {
        type: 'bar',
        data: result.map((s) => s.users),
        itemStyle: {
          color: (params: { dataIndex: number }) => {
            const colors = ['#1677ff', '#36cfc9', '#9254de', '#ffc53d', '#ff7875'];
            return colors[params.dataIndex % colors.length];
          },
        },
        label: {
          show: true,
          position: 'top',
          formatter: (p: { dataIndex: number }) => `${result[p.dataIndex]?.conversion.toFixed(1)}%`,
        },
      },
    ],
  };

  return (
    <Spin spinning={loading}>
      <div className="page-header">
        <h1 className="page-title">漏斗分析</h1>
        <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
          <RangePicker
            value={range}
            onChange={(v) => v && setRange(v as DateRange)}
            allowClear={false}
          />
          <Space.Compact>
            <InputNumber
              min={1}
              max={168}
              value={windowHours}
              onChange={(v) => setWindowHours(v ?? 24)}
            />
            <Input style={{ width: 88 }} value="小时窗口" disabled />
          </Space.Compact>
          <Button type="primary" onClick={run}>
            查询
          </Button>
        </div>
      </div>

      <Card title="配置漏斗步骤" style={{ marginBottom: 16 }}>
        <Row gutter={12}>
          {[0, 1, 2, 3, 4].map((idx) => (
            <Col span={4} key={idx}>
              <Select
                allowClear
                placeholder={`步骤 ${idx + 1}`}
                style={{ width: '100%' }}
                value={steps[idx]}
                onChange={(v) => {
                  const next = [...steps];
                  if (v) next[idx] = v;
                  else next.splice(idx, 1);
                  setSteps(next);
                }}
                options={eventNames.map((n) => ({ label: n, value: n }))}
                showSearch
              />
            </Col>
          ))}
        </Row>
      </Card>

      <Row gutter={16}>
        <Col span={16}>
          <Card title="转化漏斗">
            <ReactECharts option={chartOption} style={{ height: 380 }} />
          </Card>
        </Col>
        <Col span={8}>
          <Card title="步骤详情">
            {result.map((step, idx) => (
              <Card key={step.name} size="small" style={{ marginBottom: 8 }}>
                <div style={{ fontWeight: 600, marginBottom: 8 }}>
                  {idx + 1}. {step.name}
                </div>
                <Row gutter={8}>
                  <Col span={12}>
                    <Statistic title="人数" value={step.users} />
                  </Col>
                  <Col span={12}>
                    <Statistic title="转化率" value={step.conversion} precision={1} suffix="%" />
                  </Col>
                </Row>
              </Card>
            ))}
          </Card>
        </Col>
      </Row>
    </Spin>
  );
}
