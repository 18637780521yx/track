import {
  AlertOutlined,
  BarChartOutlined,
  DashboardOutlined,
  FileSearchOutlined,
  FilterOutlined,
  LineChartOutlined,
  TeamOutlined,
  UserOutlined,
} from '@ant-design/icons';
import { Layout, Menu, Select, Typography, message } from 'antd';
import { ReactNode, useEffect, useMemo, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { api, type TrackedApp } from '../api/client';

const { Header, Sider, Content } = Layout;

const menuItems = [
  { key: '/', icon: <DashboardOutlined />, label: '数据概览' },
  { key: '/events', icon: <LineChartOutlined />, label: '事件分析' },
  { key: '/stability', icon: <AlertOutlined />, label: '稳定性' },
  { key: '/reports', icon: <FileSearchOutlined />, label: '会话报告' },
  { key: '/funnel', icon: <FilterOutlined />, label: '漏斗分析' },
  { key: '/retention', icon: <TeamOutlined />, label: '留存分析' },
  { key: '/users', icon: <UserOutlined />, label: '用户列表' },
];

export function MainLayout({ children, appPackage, onAppChange }: {
  children: ReactNode;
  appPackage?: string;
  onAppChange: (value?: string) => void;
}) {
  const location = useLocation();
  const navigate = useNavigate();
  const [apps, setApps] = useState<TrackedApp[]>([]);
  const [loadingApps, setLoadingApps] = useState(true);

  useEffect(() => {
    api.apps()
      .then(setApps)
      .catch(() => message.error('无法加载应用列表'))
      .finally(() => setLoadingApps(false));
  }, []);

  const selectedKey = useMemo(() => {
    if (location.pathname.startsWith('/users')) return '/users';
    if (location.pathname.startsWith('/reports')) return '/reports';
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
        {selectedKey === '/' && (
          <div style={{ padding: '12px 16px 0' }}>
            <label htmlFor="overview-app">概览应用</label>
            <Select
              id="overview-app"
              value={appPackage ?? ''}
              onChange={(value) => onAppChange(value || undefined)}
              loading={loadingApps}
              style={{ width: '100%', marginTop: 4 }}
              options={[
                { value: '', label: '全部应用' },
                ...apps.map((app) => ({
                  value: app.package,
                  label: app.name && apps.filter((item) => item.name === app.name).length === 1
                    ? app.name
                    : app.package,
                })),
              ]}
            />
          </div>
        )}
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
        />
        <Content style={{ margin: 24 }}>{children}</Content>
      </Layout>
    </Layout>
  );
}
