import { ConfigProvider, App as AntApp, theme } from 'antd';
import zhCN from 'antd/locale/zh_CN';
import { useMemo, useState } from 'react';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';
import { createApi } from './api/client';
import { AppScope } from './api/scope';
import { MainLayout } from './layouts/MainLayout';
import { EventAnalysisPage } from './pages/EventAnalysis';
import { FunnelPage } from './pages/Funnel';
import { OverviewPage } from './pages/Overview';
import { PerfReportDetailPage, PerfReportPage } from './pages/PerfReport';
import { RetentionPage } from './pages/Retention';
import { StabilityPage } from './pages/Stability';
import { UserDetailPage } from './pages/UserDetail';
import { UsersPage } from './pages/Users';

export default function App() {
  const [appPackage, setAppPackage] = useState<string | undefined>(() => localStorage.getItem("track.appPackage") || undefined);
  const scope = useMemo(() => ({ api: createApi(appPackage), appPackage }), [appPackage]);
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
          <MainLayout appPackage={appPackage} onAppChange={(value) => {
            if (value) localStorage.setItem("track.appPackage", value);
            else localStorage.removeItem("track.appPackage");
            setAppPackage(value);
          }}>
            <AppScope.Provider value={scope}>
            <Routes key={appPackage ?? ''}>
              <Route path="/" element={<OverviewPage appPackage={appPackage} />} />
              <Route path="/events" element={<EventAnalysisPage />} />
              <Route path="/stability" element={<StabilityPage />} />
              <Route path="/reports" element={<PerfReportPage />} />
              <Route path="/reports/:sessionId" element={<PerfReportDetailPage />} />
              <Route path="/funnel" element={<FunnelPage />} />
              <Route path="/retention" element={<RetentionPage />} />
              <Route path="/users" element={<UsersPage />} />
              <Route path="/users/:id" element={<UserDetailPage />} />
              <Route path="*" element={<Navigate to="/" replace />} />
            </Routes>
            </AppScope.Provider>
          </MainLayout>
        </BrowserRouter>
      </AntApp>
    </ConfigProvider>
  );
}
