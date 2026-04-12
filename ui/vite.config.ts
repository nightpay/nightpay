import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

const allowedHosts = (
  process.env.VITE_ALLOWED_HOSTS
    ? process.env.VITE_ALLOWED_HOSTS.split(',').map((h) => h.trim()).filter(Boolean)
    : [
        'nightpay.dev',
        'www.nightpay.dev',
        'board.nightpay.dev',
        'api.nightpay.dev',
        'docs.nightpay.dev',
        'ceo.nightpay.dev',
        'staging.nightpay.dev',
        'api.staging.nightpay.dev',
        'bridge.staging.nightpay.dev',
        'localhost',
        '127.0.0.1',
      ]
);

export default defineConfig({
  plugins: [react()],
  server: {
    port: 3333,
    // Explicit host allowlist to avoid random host-check failures on VPS/Caddy.
    allowedHosts,
    fs: {
      // Allow importing local skill files from ../skills into the UI.
      allow: ['..'],
    },
    proxy: {
      // Bridge: health, stats, verifyReceipt (port 4000)
      '/api': {
        // Use IPv4 loopback to avoid ::1 proxy failures when backend binds 0.0.0.0.
        target: process.env.VITE_BRIDGE_URL ?? 'http://127.0.0.1:4000',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, ''),
      },
      // MIP-003 server: jobs, availability, input_schema (port 8090)
      '/mip': {
        target: process.env.VITE_MIP_URL ?? 'http://127.0.0.1:8090',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/mip/, ''),
      },
      // Ontology proxy: route directly to MIP-003 server
      '/ontology': {
        target: process.env.VITE_MIP_URL ?? 'http://127.0.0.1:8090',
        changeOrigin: true,
      },
    },
  },
  build: {
    outDir: 'dist',
    sourcemap: true,
  },
});
