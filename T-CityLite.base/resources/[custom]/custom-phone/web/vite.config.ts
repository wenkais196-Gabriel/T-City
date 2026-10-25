import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'

// https://vite.dev/config/
// Content-hashed asset names are deliberate: CEF caches the NUI page per iframe
// and `assets/index.js` without a hash can be served from that cache after a
// `restart custom-phone`, so a rebuilt phone keeps running yesterday's JS while
// Lua already has the new code. A hash makes a stale bundle impossible — the
// old file is simply never referenced again.
export default defineConfig({
  plugins: [svelte()],
  base: './',
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
