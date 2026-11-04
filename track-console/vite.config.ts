import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    port: 3000,
    proxy: {
      // 本地调试：默认走本机 track-server-py；可用 VITE_API_PROXY 覆盖
      '/api': process.env.VITE_API_PROXY || 'http://127.0.0.1:8080',
      '/track': process.env.VITE_API_PROXY || 'http://127.0.0.1:8080',
    },
  },
});
