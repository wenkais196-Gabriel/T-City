import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'

// https://vite.dev/config/
// Content-hashed asset names are deliberate: CEF caches the NUI page per iframe
// and `assets/index.js` without a hash can be served from that cache after a
// `restart custom-phone`, so a rebuilt phone keeps running yesterday's JS while
// Lua already has the new code. A hash makes a stale bundle impossible — the
// old file is simply never referenced again.
// Build id 注入：页面加载时把它报给服务端（nuiReady 握手），用来证明"跑的是新包"。
const buildId = new Date().toISOString().replace(/[-:T.]/g, '').slice(0, 14)

export default defineConfig({
  plugins: [svelte()],
  base: './',
  define: {
    __NUI_BUILD__: JSON.stringify(buildId),
  },
  build: {
    outDir: '../html',
    emptyOutDir: true,
    assetsDir: 'assets',
    rollupOptions: {
      output: {
        entryFileNames: 'assets/[name]-[hash].js',
        chunkFileNames: 'assets/[name]-[hash].js',
        assetFileNames: 'assets/[name]-[hash].[ext]'
      }
    }
  }
})
