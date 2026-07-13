import { Card, Input, Spin, Table, Tag, message } from 'antd';
import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { api, UserRecord } from '../api/client';

export function UsersPage() {
  const navigate = useNavigate();
  const [loading, setLoading] = useState(false);
  const [users, setUsers] = useState<UserRecord[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [keyword, setKeyword] = useState('');
  const [search, setSearch] = useState('');

  useEffect(() => {
    setLoading(true);
    api
      .listUsers(search, 20, (page - 1) * 20)
      .then((res) => {
        setUsers(res.items);
        setTotal(res.total);
      })
      .catch((e) => message.error(e.message))
      .finally(() => setLoading(false));
  }, [page, search]);

  return (
    <Spin spinning={loading}>
      <div className="page-header">
        <h1 className="page-title">用户列表</h1>
        <Input.Search
          allowClear
          placeholder="搜索用户 ID / 登录 ID / 匿名 ID"
          style={{ width: 320 }}
          value={keyword}
          onChange={(e) => setKeyword(e.target.value)}
          onSearch={(v) => {
            setPage(1);
            setSearch(v.trim());
          }}
        />
      </div>

      <Card>
        <Table
          rowKey="user_id"
          dataSource={users}
          onRow={(record) => ({
            onClick: () => navigate(`/users/${encodeURIComponent(record.user_id)}`),
            style: { cursor: 'pointer' },
          })}
          pagination={{
            current: page,
            pageSize: 20,
            total,
            onChange: setPage,
            showTotal: (t) => `共 ${t} 人`,
          }}
          columns={[
            {
              title: '用户 ID',
              dataIndex: 'user_id',
              width: 180,
              ellipsis: true,
              render: (v: string) => <a>{v}</a>,
            },
            {
              title: '类型',
              width: 90,
              render: (_, r) =>
                r.distinct_id ? <Tag color="blue">登录</Tag> : <Tag>匿名</Tag>,
            },
            { title: '渠道', dataIndex: 'channel', width: 110, render: (v) => v || '-' },
            {
              title: '首次访问',
              dataIndex: 'first_seen_at',
              width: 170,
              render: (v: string) => new Date(v).toLocaleString(),
            },
            {
              title: '最近访问',
              dataIndex: 'last_seen_at',
              width: 170,
              render: (v: string) => new Date(v).toLocaleString(),
            },
            {
              title: '付费',
              width: 80,
              render: (_, r) =>
                r.is_paid ? <Tag color="gold">是</Tag> : <Tag>否</Tag>,
            },
            {
              title: '累计收入',
              dataIndex: 'total_revenue',
              width: 100,
              render: (v: number) => (v > 0 ? `¥${v.toFixed(2)}` : '-'),
            },
          ]}
        />
      </Card>
    </Spin>
  );
}
