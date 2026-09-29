import { Empty, Typography } from 'antd';

const { Text } = Typography;

type JsonValue = Record<string, unknown> | unknown[] | null | undefined;

interface JsonPanelProps {
  value: JsonValue;
  label?: string;
}

export function JsonPanel({ value, label }: JsonPanelProps) {
  const empty =
    value == null ||
    (typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length === 0) ||
    (Array.isArray(value) && value.length === 0);

  return (
    <div className="json-panel">
      {label && (
        <Text type="secondary" className="json-panel-label">
          {label}
        </Text>
      )}
      {empty ? (
        <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="无数据" style={{ margin: 0 }} />
      ) : (
        <pre className="json-panel-pre">{JSON.stringify(value, null, 2)}</pre>
      )}
    </div>
  );
}
