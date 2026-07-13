import {
  BarChartOutlined,
  DashboardOutlined,
  FilterOutlined,
  LineChartOutlined,
  TeamOutlined,
  UserOutlined,
} from '@ant-design/icons';
import { Layout, Menu, Typography } from 'antd';
import { ReactNode, useMemo } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';

const { Header, Sider, Content } = Layout;

const menuItems = [
  { key: '/', icon: <DashboardOutlined />, label: '数据概览' },
  { key: '/events', icon: <LineChartOutlined />, label: '事件分析' },
  { key: '/funnel', icon: <FilterOutlined />, label: '漏斗分析' },
  { key: '/retention', icon: <TeamOutlined />, label: '留存分析' },
  { key: '/users', icon: <UserOutlined />, label: '用户列表' },
];

export function MainLayout({ children }: { children: ReactNode }) {
  const location = useLocation();
  const navigate = useNavigate();

  const selectedKey = useMemo(() => {
    const hit = menuItems.find((item) => location.pathname === item.key);
    return hit?.key ?? '/';
  }, [location.pathname]);

  return (
    <Layout style={{ minHeight: '100vh' }}>
      <Sider width={220} theme="light" style={{ borderRight: '1px solid #e8e8e8' }}>
        <div style={{ padding: '20px 16px', borderBottom: '1px solid #f0f0f0' }}>
          <Typography.Title level={4} style={{ margin: 0, color: '#1677ff' }}>
            <BarChartOutlined style={{ marginRight: 8 }} />
            Track
          </Typography.Title>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            数据分析平台
          </Typography.Text>
        </div>
        <Menu
          mode="inline"
          selectedKeys={[selectedKey]}
          items={menuItems}
          onClick={({ key }) => navigate(key)}
          style={{ borderInlineEnd: 0, marginTop: 8 }}
        />
      </Sider>
      <Layout>
        <Header
          style={{
            background: '#fff',
            padding: '0 24px',
            borderBottom: '1px solid #f0f0f0',
            display: 'flex',
            alignItems: 'center',
          }}
        >
          <Typography.Text type="secondary">仿神策 MVP · 与 fast_track SDK 对接</Typography.Text>
        </Header>
        <Content style={{ margin: 24 }}>{children}</Content>
      </Layout>
    </Layout>
  );
}
