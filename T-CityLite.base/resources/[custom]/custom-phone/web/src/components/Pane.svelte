<script lang="ts">
  // Pane.svelte — 一个面板。只负责标记身份与自己滚，排布由 AppSurface 决定。
  import { getContext } from 'svelte';

  let {
    id,
    scroll = 'self',
    children,
  }: { id: string; scroll?: 'self' | 'none'; children?: any } = $props();

  const ctx = getContext<{ active: () => string; hidden: (id: string) => boolean } | null>('pane');
  const isActive = $derived(!ctx || ctx.active() === id);

  // scroll='self'：面板自己滚；'none'：面板不滚，内部再分（聊天输入栏常驻底部）
  const overflow = scroll === 'self' ? 'auto' : 'hidden';
</script>

<div class="pane" data-pane={id} data-active={isActive ? 'true' : 'false'} style:overflow-y={overflow}>
  {@render children?.()}
</div>

<style>
  .pane {
    min-width: 0;
    min-height: 0;
    display: flex;
    flex-direction: column;
    overflow-x: hidden;
    overflow-y: auto;
  }
</style>
