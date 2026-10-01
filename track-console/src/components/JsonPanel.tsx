import { Typography } from 'antd';

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

  if (empty) return null;

  return (
    <div className="json-panel">
      {label && (
        <Text type="secondary" className="json-panel-label">
          {label}
        </Text>
      )}
      <pre className="json-panel-pre">{JSON.stringify(value, null, 2)}</pre>
    </div>
  );
}
