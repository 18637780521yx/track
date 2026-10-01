import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    port: 3000,
    proxy: {
      // 本地调试：默认走线上 API；本地后端可用 VITE_API_PROXY 覆盖
      '/api': process.env.VITE_API_PROXY || 'http://101.126.68.169:5000',
      '/track': process.env.VITE_API_PROXY || 'http://101.126.68.169:5000',
    },
  },
});
