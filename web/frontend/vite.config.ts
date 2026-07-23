import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// In development the React dev server proxies API calls to the Dart backend on
// :8080. In production the backend serves the built files, so /api is same-origin.
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      '/api': 'http://localhost:8080',
    },
  },
  build: {
    outDir: 'dist',
  },
})
