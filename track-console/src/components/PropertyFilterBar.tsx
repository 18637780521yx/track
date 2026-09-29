import { AutoComplete, Button, Input, Select, Space } from 'antd';
import { PlusOutlined, DeleteOutlined } from '@ant-design/icons';

export type FilterOp = 'eq' | 'neq' | 'contains';
export type FilterSource = 'common' | 'properties';

export interface PropertyFilter {
  id: string;
  source: FilterSource;
  field: string;
  op: FilterOp;
  value: string;
}

export const COMMON_FIELDS = [
  { value: 'environment', label: 'environment 环境' },
  { value: 'build_mode', label: 'build_mode 编译模式' },
  { value: 'app_version', label: 'app_version 版本' },
  { value: 'app_build', label: 'app_build 构建号' },
  { value: 'device_os', label: 'device_os 系统' },
  { value: 'device_os_version', label: 'device_os_version 系统版本' },
  { value: 'device_model', label: 'device_model 机型' },
  { value: 'app_name', label: 'app_name 应用名' },
  { value: 'locale', label: 'locale 语言区域' },
  { value: 'language', label: 'language 语言' },
  { value: 'network_type', label: 'network_type 网络' },
  { value: 'sdk_version', label: 'sdk_version SDK版本' },
];

const OPS = [
  { value: 'eq', label: '等于' },
  { value: 'neq', label: '不等于' },
  { value: 'contains', label: '包含' },
];

let seq = 0;
export function newFilter(partial?: Partial<PropertyFilter>): PropertyFilter {
  seq += 1;
  return {
    id: `f-${Date.now()}-${seq}`,
    source: 'common',
    field: 'environment',
    op: 'eq',
    value: '',
    ...partial,
  };
}

interface Props {
  filters: PropertyFilter[];
  onChange: (filters: PropertyFilter[]) => void;
  valueOptions?: Record<string, string[]>;
  onLoadValues?: (filter: PropertyFilter) => void;
}

export function PropertyFilterBar({ filters, onChange, valueOptions = {}, onLoadValues }: Props) {
  const update = (id: string, patch: Partial<PropertyFilter>) => {
    onChange(filters.map((f) => (f.id === id ? { ...f, ...patch } : f)));
  };

  return (
    <div className="filter-bar">
      {filters.map((f, index) => {
        const optKey = `${f.source}:${f.field}`;
        return (
          <Space key={f.id} wrap style={{ marginBottom: 8 }} align="center">
            {index > 0 && <span className="filter-and">且</span>}
            <Select
              style={{ width: 120 }}
              value={f.source}
              options={[
                { value: 'common', label: '公共属性' },
                { value: 'properties', label: '事件属性' },
              ]}
              onChange={(source) =>
                update(f.id, {
                  source,
                  field: source === 'common' ? 'environment' : '',
                  value: '',
                })
              }
            />
            {f.source === 'common' ? (
              <Select
                style={{ width: 200 }}
                value={f.field}
                options={COMMON_FIELDS}
                onChange={(field) => {
                  update(f.id, { field, value: '' });
                  onLoadValues?.({ ...f, field, value: '' });
                }}
              />
            ) : (
              <Input
                style={{ width: 160 }}
                placeholder="属性名，如 pageName"
                value={f.field}
                onChange={(e) => update(f.id, { field: e.target.value })}
                onBlur={() => f.field.trim() && onLoadValues?.(f)}
              />
            )}
            <Select
              style={{ width: 100 }}
              value={f.op}
              options={OPS}
              onChange={(op) => update(f.id, { op })}
            />
            <AutoComplete
              style={{ width: 200 }}
              value={f.value}
              options={(valueOptions[optKey] ?? []).map((v) => ({ value: v }))}
              placeholder="筛选值"
              onChange={(v) => update(f.id, { value: v })}
              onFocus={() => onLoadValues?.(f)}
              filterOption={(input, option) =>
                String(option?.value ?? '')
                  .toLowerCase()
                  .includes(input.toLowerCase())
              }
            />
            <Button
              type="text"
              danger
              icon={<DeleteOutlined />}
              onClick={() => onChange(filters.filter((x) => x.id !== f.id))}
            />
          </Space>
        );
      })}
      <Button type="dashed" icon={<PlusOutlined />} onClick={() => onChange([...filters, newFilter()])}>
        添加条件
      </Button>
    </div>
  );
}

/** Only filters with both field and value filled */
export function activeFilters(filters: PropertyFilter[]) {
  return filters
    .filter((f) => f.field.trim() && f.value.trim())
    .map(({ source, field, op, value }) => ({
      source,
      field: field.trim(),
      op,
      value: value.trim(),
    }));
}
