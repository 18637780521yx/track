import { Card, DatePicker, Input, InputNumber, Select, Space, Spin, Table, message } from 'antd';
import { useEffect, useState } from 'react';
import { api, DateRange, defaultRange, RetentionRow } from '../api/client';

const { RangePicker } = DatePicker;

function retentionColor(rate: number) {
  if (rate >= 40) return '#1677ff';
  if (rate >= 20) return '#69b1ff';
  if (rate >= 10) return '#bae0ff';
  if (rate > 0) return '#e6f4ff';
  return '#f5f5f5';
}

export function RetentionPage() {
  const [range, setRange] = useState<DateRange>(defaultRange(14));
  const [eventNames, setEventNames] = useState<string[]>([]);
  const [cohortEvent, setCohortEvent] = useState('app_first_open');
  const [returnEvent, setReturnEvent] = useState('app_first_open');
  const [days, setDays] = useState(7);
  const [loading, setLoading] = useState(false);
  const [rows, setRows] = useState<RetentionRow[]>([]);
  const [dayList, setDayList] = useState<number[]>([]);

  useEffect(() => {
    api.eventNames()
      .then((res) => {
        const names = res.items.map((i) => i.name);
        setEventNames(names);
        if (names.includes('app_first_open')) {
          setCohortEvent('app_first_open');
          setReturnEvent('app_first_open');
        } else if (names.length > 0) {
          setCohortEvent(names[0]);
          setReturnEvent(names[0]);
        }
      })
      .catch((e) => message.error(e.message));
  }, []);

  useEffect(() => {
    setLoading(true);
    api
      .retention(range, cohortEvent, returnEvent, days)
      .then((res) => {
        setRows(res.rows);
        setDayList(res.days);
      })
      .catch((e) => message.error(e.message))
      .finally(() => setLoading(false));
  }, [range, cohortEvent, returnEvent, days]);

  const columns = [
    { title: '分组日期', dataIndex: 'cohort_date', width: 120, fixed: 'left' as const },
    { title: '分组人数', dataIndex: 'cohort_size', width: 100 },
    ...dayList.map((day) => ({
      title: day === 0 ? '当日' : `第${day}日`,
      width: 72,
      render: (_: unknown, record: RetentionRow) => {
        const rate = record.retention[day] ?? 0;
        return (
          <div
            className="retention-cell"
            style={{
              background: retentionColor(rate),
              color: rate >= 20 ? '#fff' : '#1f2329',
            }}
          >
            {rate.toFixed(1)}%
          </div>
        );
      },
    })),
  ];

  return (
    <Spin spinning={loading}>
      <div className="page-header">
        <h1 className="page-title">留存分析</h1>
        <div style={{ display: 'flex', gap: 12 }}>
          <Select
            style={{ width: 180 }}
            value={cohortEvent}
            onChange={setCohortEvent}
            options={eventNames.map((n) => ({ label: `初始: ${n}`, value: n }))}
            showSearch
          />
          <Select
            style={{ width: 180 }}
            value={returnEvent}
            onChange={setReturnEvent}
            options={eventNames.map((n) => ({ label: `回访: ${n}`, value: n }))}
            showSearch
          />
          <Space.Compact>
            <InputNumber min={1} max={30} value={days} onChange={(v) => setDays(v ?? 7)} />
            <Input style={{ width: 48 }} value="天" disabled />
          </Space.Compact>
          <RangePicker
            value={range}
            onChange={(v) => v && setRange(v as DateRange)}
            allowClear={false}
          />
        </div>
      </div>

      <Card title="留存表格">
        <Table
          rowKey="cohort_date"
          size="small"
          scroll={{ x: 900 }}
          pagination={false}
          dataSource={rows}
          columns={columns}
        />
      </Card>
    </Spin>
  );
}
