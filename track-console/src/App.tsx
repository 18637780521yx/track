import { ConfigProvider, App as AntApp, theme } from 'antd';
import zhCN from 'antd/locale/zh_CN';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';
import { MainLayout } from './layouts/MainLayout';
import { EventAnalysisPage } from './pages/EventAnalysis';
import { FunnelPage } from './pages/Funnel';
import { OverviewPage } from './pages/Overview';
import { RetentionPage } from './pages/Retention';
import { UserDetailPage } from './pages/UserDetail';
import { UsersPage } from './pages/Users';

export default function App() {
  return (
    <ConfigProvider
      locale={zhCN}
      theme={{
        algorithm: theme.defaultAlgorithm,
        token: {
          colorPrimary: '#1677ff',
          borderRadius: 6,
        },
      }}
    >
      <AntApp>
        <BrowserRouter>
          <MainLayout>
            <Routes>
              <Route path="/" element={<OverviewPage />} />
              <Route path="/events" element={<EventAnalysisPage />} />
              <Route path="/funnel" element={<FunnelPage />} />
              <Route path="/retention" element={<RetentionPage />} />
              <Route path="/users" element={<UsersPage />} />
              <Route path="/users/:id" element={<UserDetailPage />} />
              <Route path="*" element={<Navigate to="/" replace />} />
            </Routes>
          </MainLayout>
        </BrowserRouter>
      </AntApp>
    </ConfigProvider>
  );
}
